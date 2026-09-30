import Foundation

/// An error from a workflow action. `message` matches the CLI's `error:` line
/// (without the prefix), so the app and the terminal say the same thing.
public struct GTDError: LocalizedError, Equatable {
    public let message: String
    public let detail: String?

    public init(_ message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    public var errorDescription: String? { detail.map { "\(message)\n\($0)" } ?? message }
}

/// One file moved by ingestion.
public struct IngestResult: Hashable {
    public let oldName: String
    public let newName: String
    public let messageRef: String
}

/// What `metadata_check` found.
public struct MetadataCheckReport: Hashable {
    /// Rows whose `eml_filename` no longer exists (the check drops them).
    public let missingFiles: [String]
    /// (email, referenced filename) for `next_action` references to missing files.
    public let danglingRefs: [DanglingRef]
    public var isClean: Bool { missingFiles.isEmpty && danglingRefs.isEmpty }
}

public struct DanglingRef: Hashable {
    public let filename: String
    public let reference: String
}

/// A workspace folder on disk: `01-input` … `06-archive` plus `metadata.csv`.
/// Every mutating method reproduces the corresponding `gtd.py` command,
/// including its refusals, and writes `metadata.csv` exactly as it would.
public final class Workspace {
    public let root: URL
    /// The date written into ds_* stamps (the CLI uses the local date).
    public var today: () -> Day = { Day.today() }
    /// Used only when an email has no usable Date header (the CLI uses now).
    public var now: () -> Date = { Date() }

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    private var fm: FileManager { .default }

    public func folderURL(_ folder: Folder) -> URL {
        root.appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    public func url(_ folder: Folder, _ filename: String) -> URL {
        folderURL(folder).appendingPathComponent(filename)
    }

    public var metadataURL: URL { Metadata.url(root) }
    public var configURL: URL { root.appendingPathComponent(WorkspaceConfig.fileName) }

    /// True when the folder looks like a gtd-eml workspace already.
    public static func looksLikeWorkspace(_ root: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent(Metadata.fileName).path) { return true }
        return Folder.allCases.contains { fm.fileExists(atPath: root.appendingPathComponent($0.rawValue).path) }
    }

    /// `fs.ensure_folders`.
    public func ensureFolders() throws {
        for folder in Folder.allCases {
            try fm.createDirectory(at: folderURL(folder), withIntermediateDirectories: true)
        }
    }

    /// `fs.list_eml_files`: sorted names of regular `.eml` files.
    public func listEML(_ folder: Folder) -> [String] {
        let dir = folderURL(folder)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { name in
            guard name.lowercased().hasSuffix(".eml") else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir) && !isDir.boolValue
        }.sorted(by: codePointPrecedes)
    }

    /// `fs.all_existing_filenames`.
    public func allExistingFilenames() -> Set<String> {
        var names = Set<String>()
        for folder in Folder.allCases { names.formUnion(listEML(folder)) }
        return names
    }

    /// `fs.find_eml`: the first folder (in workflow order) holding the file.
    public func find(_ filename: String) -> (folder: Folder, name: String)? {
        let name = filename.lowercased().hasSuffix(".eml") ? filename : filename + ".eml"
        for folder in Folder.allCases {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url(folder, name).path, isDirectory: &isDir), !isDir.boolValue {
                return (folder, name)
            }
        }
        return nil
    }

    public func loadMetadata() -> [String: Metadata.Row] { Metadata.load(root: root) }

    /// `sync_metadata(base_dir, new_values=seeds)`.
    public func syncMetadata(seeds: [String: Metadata.Row] = [:]) throws {
        let rows = Metadata.synced(loadMetadata(), current: allExistingFilenames(), seeds: seeds)
        try Metadata.write(rows, root: root)
    }

    /// `set_metadata_value` for several fields at once: sync, then set. The
    /// result is byte-identical to calling the CLI once per field.
    public func updateMetadata(_ filename: String, _ changes: [String: String]) throws {
        for field in changes.keys where !Metadata.writable.contains(field) {
            throw GTDError("field '\(field)' is not editable",
                           detail: "editable fields: " + Metadata.editable.joined(separator: ", "))
        }
        let current = allExistingFilenames()
        guard current.contains(filename) else { throw GTDError("'\(filename)' is not in the workflow") }
        var rows = Metadata.synced(loadMetadata(), current: current)
        var row = rows[filename] ?? Metadata.blankRow()
        for (field, value) in changes { row[field] = value }
        rows[filename] = row
        try Metadata.write(rows, root: root)
    }

    private func notFound(_ filename: String, suffix: String = "") -> GTDError {
        GTDError("'\(filename)' not found in any GTD folder under \(root.path)\(suffix)")
    }

    private func locate(_ filename: String, suffix: String = "") throws -> (folder: Folder, name: String) {
        guard let found = find(filename) else { throw notFound(filename, suffix: suffix) }
        return found
    }

    private func move(_ name: String, from src: Folder, to dest: Folder) throws {
        try fm.createDirectory(at: folderURL(dest), withIntermediateDirectories: true)
        let target = url(dest, name)
        if fm.fileExists(atPath: target.path) {
            throw GTDError("a file named '\(name)' already exists in \(dest.rawValue)")
        }
        try fm.moveItem(at: url(src, name), to: target)
    }

    // MARK: Ingest (`gtd list`)

    /// Rename every `.eml` in 01-input per the naming convention and move it
    /// to 02-triage, then sync metadata.csv, seeding ds_triage (today) and
    /// message_ref for the new rows.
    @discardableResult
    public func ingest(maxFilenameChars: Int) throws -> [IngestResult] {
        try ensureFolders()
        var existing = allExistingFilenames()
        var moved: [IngestResult] = []
        var failure: Error?
        for oldName in listEML(.input) {
            let source = url(.input, oldName)
            let parsed: MIMEEntity
            do {
                parsed = MIMEParser.parse(try Data(contentsOf: source))
            } catch {
                failure = GTDError("could not read '\(oldName)': \(error.localizedDescription)")
                break
            }
            let date = EmailUtil.date(parsed) ?? DateParsing.now(now())
            let subject = EmailUtil.subject(parsed)
            let ref = EmailUtil.findMessageRef(parsed)
            let base = Naming.buildBaseFilename(day: date.day, subject: subject, maxChars: maxFilenameChars,
                                                messageRef: ref)
            let newName = Naming.uniqueFilename(base: base, existing: existing, maxChars: maxFilenameChars,
                                                messageRef: ref)
            existing.insert(newName)
            do {
                try fm.moveItem(at: source, to: url(.triage, newName))
            } catch {
                failure = error
                break
            }
            moved.append(IngestResult(oldName: oldName, newName: newName, messageRef: ref ?? ""))
        }
        let stamp = today().iso
        var seeds: [String: Metadata.Row] = [:]
        for m in moved {
            var seed = ["ds_triage": stamp]
            if !m.messageRef.isEmpty { seed["message_ref"] = m.messageRef }
            seeds[m.newName] = seed
        }
        try syncMetadata(seeds: seeds)
        if let failure { throw failure }
        return moved
    }

    // MARK: alloc / close

    public enum AllocOutcome: Equatable {
        case moved(from: Folder, to: Folder)
        case alreadyThere(Folder)
    }

    /// Why `alloc` would refuse, without doing anything (for disabling UI).
    public func allocRefusal(_ filename: String, to dest: Folder, metadata: [String: Metadata.Row]? = nil) -> GTDError? {
        guard let found = find(filename) else { return notFound(filename) }
        let (src, name) = (found.folder, found.name)
        if src == dest { return nil }
        if let field = dest.stampField {
            let existing = (metadata ?? loadMetadata())[name]?[field] ?? ""
            if !existing.isEmpty {
                return GTDError("'\(name)' already has \(field) = \(existing); refusing to move it to \(dest.rawValue) and overwrite that date.",
                                detail: "Please handle this email manually.")
            }
        }
        return nil
    }

    /// `gtd alloc <file> <destination>`.
    @discardableResult
    public func alloc(_ filename: String, to dest: Folder) throws -> AllocOutcome {
        let (src, name) = try locate(filename)
        if src == dest { return .alreadyThere(dest) }
        if let refusal = allocRefusal(name, to: dest) { throw refusal }
        try move(name, from: src, to: dest)
        if let field = dest.stampField {
            try updateMetadata(name, [field: today().iso])
        }
        return .moved(from: src, to: dest)
    }

    /// Why `close` would refuse, without doing anything.
    public func closeRefusal(_ filename: String, metadata: [String: Metadata.Row]? = nil) -> GTDError? {
        guard let found = find(filename) else { return notFound(filename) }
        let (src, name) = (found.folder, found.name)
        if src == .archive {
            return GTDError("'\(name)' is already in \(Folder.archive.rawValue); refusing to close it again")
        }
        let existing = (metadata ?? loadMetadata())[name]?["ds_archive"] ?? ""
        if !existing.isEmpty {
            return GTDError("'\(name)' already has ds_archive = \(existing); refusing to close it and overwrite that date.",
                            detail: "Please handle this email manually.")
        }
        return nil
    }

    /// `gtd close <file> with <other>`: archive it, record what closed it.
    public func close(_ filename: String, with other: String) throws {
        let (src, name) = try locate(filename)
        let otherName = try locate(other, suffix: "; nothing was changed").name
        if let refusal = closeRefusal(name) { throw refusal }
        try move(name, from: src, to: .archive)
        try updateMetadata(name, ["next_action": "Closed with \(otherName)", "ds_archive": today().iso])
    }

    // MARK: Flags and annotations

    /// `gtd pin` / `gtd unpin`. Returns false when nothing changed.
    @discardableResult
    public func setFlag(_ filename: String, _ flag: String, on: Bool) throws -> Bool {
        let name = try locate(filename).name
        let current = loadMetadata()[name]?["flags"] ?? ""
        var tokens = current.pyWords
        if on {
            if tokens.contains(flag) { return false }
            tokens.append(flag)
        } else {
            if !tokens.contains(flag) { return false }
            tokens.removeAll { $0 == flag }
        }
        try updateMetadata(name, ["flags": tokens.joined(separator: " ")])
        return true
    }

    /// `gtd metadata <file> set <field> = <value>` for the editable fields.
    /// Returns the CLI's warning for a due date that is not yyyy-mm-dd.
    @discardableResult
    public func setFields(_ filename: String, _ changes: [String: String]) throws -> [String] {
        let name = try locate(filename).name
        for field in changes.keys where !Metadata.editable.contains(field) {
            throw GTDError("field '\(field)' is not editable",
                           detail: "editable fields: " + Metadata.editable.joined(separator: ", "))
        }
        guard !changes.isEmpty else { return [] }
        try updateMetadata(name, changes)
        var warnings: [String] = []
        if let due = changes["due_date"], !due.pyStrip.isEmpty, !Rules.isISODate(due) {
            warnings.append("due_date '\(due.pyStrip)' is not in yyyy-mm-dd form, so it cannot be compared against today's date.")
        }
        return warnings
    }

    // MARK: metadata_check

    static let emlInText = Rx("\\S+\\.eml", [.caseInsensitive])

    /// What `gtd metadata_check` would report, without changing anything.
    public func previewMetadataCheck() -> MetadataCheckReport {
        let rows = loadMetadata()
        let onDisk = allExistingFilenames()
        let missing = rows.keys.filter { !onDisk.contains($0) }.sorted(by: codePointPrecedes)
        var dangling: [DanglingRef] = []
        for name in rows.keys.sorted(by: codePointPrecedes) {
            for m in Workspace.emlInText.allMatches(rows[name]?["next_action"] ?? "") {
                let ref = m.group(0) ?? ""
                if !onDisk.contains(ref) { dangling.append(DanglingRef(filename: name, reference: ref)) }
            }
        }
        return MetadataCheckReport(missingFiles: missing, danglingRefs: dangling)
    }

    /// `gtd metadata_check`: report, then reconcile metadata.csv.
    @discardableResult
    public func metadataCheck() throws -> MetadataCheckReport {
        try ensureFolders()
        let report = previewMetadataCheck()
        try syncMetadata()
        return report
    }

    // MARK: workflow_autofix

    /// The autofix records (folders 02–06) against the metadata as it will be
    /// once synced, so planning never writes.
    public func autofixRecords(metadata: [String: Metadata.Row]? = nil) -> [AutofixRecord] {
        let synced = Metadata.synced(metadata ?? loadMetadata(), current: allExistingFilenames())
        var records: [AutofixRecord] = []
        for folder in Folder.allCases where folder != .input {
            for name in listEML(folder) {
                records.append(AutofixRecord(filename: name, folder: folder, row: synced[name] ?? [:]))
            }
        }
        return records
    }

    /// `gtd workflow_autofix`'s plan (or its refusal while 01-input is not empty).
    public func planAutofix(metadata: [String: Metadata.Row]? = nil) -> AutofixPlan {
        let pending = listEML(.input).count
        let (fixes, blockers) = Analytics.planAutofix(autofixRecords(metadata: metadata), today: today())
        return AutofixPlan(pendingInput: pending, fixes: fixes, blockers: blockers)
    }

    /// Apply a plan in one batch (the CLI's single yes/no).
    public func applyAutofix(_ plan: AutofixPlan) throws {
        let pending = listEML(.input).count
        if pending > 0 {
            throw GTDError("\(pending) file(s) are still in \(Folder.input.rawValue); workflow_autofix cannot run.",
                           detail: "Ingest them into \(Folder.triage.rawValue) first, then try again.")
        }
        if !plan.blockers.isEmpty {
            throw GTDError("\(plan.blockers.count) email(s) cannot be fixed automatically and must be resolved by hand first.")
        }
        try ensureFolders()
        let current = allExistingFilenames()
        var rows = Metadata.synced(loadMetadata(), current: current)
        for fix in plan.fixes {
            guard current.contains(fix.filename) else { throw GTDError("'\(fix.filename)' is not in the workflow") }
            var row = rows[fix.filename] ?? Metadata.blankRow()
            row[fix.field] = fix.new
            rows[fix.filename] = row
        }
        try Metadata.write(rows, root: root)
    }

    // MARK: Adding files

    /// Copy `.eml` files into 01-input (never overwriting). Returns the names
    /// used. Ingestion itself stays a separate, explicit step.
    @discardableResult
    public func importToInput(_ urls: [URL]) throws -> [String] {
        try ensureFolders()
        var added: [String] = []
        for source in urls where source.pathExtension.lowercased() == "eml" {
            var name = source.lastPathComponent
            let stem = source.deletingPathExtension().lastPathComponent
            var n = 2
            while fm.fileExists(atPath: url(.input, name).path) {
                name = "\(stem)-\(n).eml"
                n += 1
            }
            try fm.copyItem(at: source, to: url(.input, name))
            added.append(name)
        }
        return added
    }
}
