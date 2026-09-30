import AppKit
import Observation
import UniformTypeIdentifiers
import GTDCore

/// A sidebar entry.
enum SidebarItem: Hashable {
    case dashboard, performance
    case folder(Folder)
    case dueSet, noDue, pinned
    case hashtag(String)
    /// Emails received by one of my accounts (nil: any of them).
    case inbox(String?)
    /// Emails sent from one of my accounts (nil: any of them).
    case sent(String?)
    /// The emails behind a Dashboard figure or project.
    case attention(String)
    case project(String)

    var isMailbox: Bool { self != .dashboard && self != .performance }
}

enum SortKey: String, CaseIterable, Identifiable {
    case date, correspondent, subject, due, folder
    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "Date"
        case .correspondent: return "Correspondent"
        case .subject: return "Subject"
        case .due: return "Due Date"
        case .folder: return "Folder"
        }
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The one sheet that can be open over the main window.
enum ActiveSheet: Identifiable {
    case closeWith(String)
    case reviewDateStamps
    case checkMetadata(MetadataCheckReport)

    var id: String {
        switch self {
        case .closeWith(let id): return "close-\(id)"
        case .reviewDateStamps: return "review"
        case .checkMetadata: return "check"
        }
    }
}

/// A run of list rows under one date heading.
struct ListGroup: Identifiable {
    let title: String
    var records: [EmailRecord]
    var id: String { title }
}

@MainActor
@Observable
final class AppModel {
    private(set) var workspace: Workspace?
    private(set) var config = WorkspaceConfig()
    private(set) var configError: String?
    private(set) var records: [EmailRecord] = []
    private(set) var recordsByID: [String: EmailRecord] = [:]
    private(set) var metrics: [EmailMetrics] = []
    private(set) var autofix = AutofixPlan(pendingInput: 0, fixes: [], blockers: [])
    private(set) var overview = Overview([])
    private(set) var metadataRows: [String: Metadata.Row] = [:]
    private(set) var isLoading = false
    private(set) var statusMessage: String?

    var sidebarSelection: SidebarItem? = .folder(.triage) {
        didSet {
            guard oldValue != sidebarSelection else { return }
            // Choosing a sidebar entry ends a search, as in Mail.
            if sidebarSelection != nil && !searchText.isEmpty { searchText = "" }
            keepSelectionVisible()
        }
    }
    var selection: Set<String> = [] {
        didSet {
            if let editing = editingAnnotationsID, !selection.contains(editing) { editingAnnotationsID = nil }
        }
    }
    var searchText = ""
    var collapsedGroups: Set<String> = []
    var activeSheet: ActiveSheet?
    var alert: AlertInfo?
    var quickLookURL: URL?
    /// The record whose annotations card is in edit mode.
    var editingAnnotationsID: String?
    private(set) var recentWorkspaces: [String] = Prefs.recentWorkspaces

    var sortKey: SortKey = Prefs.sortKey { didSet { Prefs.sortKey = sortKey } }
    var sortAscending: Bool = Prefs.sortAscending { didSet { Prefs.sortAscending = sortAscending } }
    var showDateHeadings: Bool = Prefs.dateHeadings { didSet { Prefs.dateHeadings = showDateHeadings } }
    var dateStyle: DateStyle = Prefs.dateStyle { didSet { Prefs.dateStyle = dateStyle } }
    var timeZoneID: String = Prefs.timeZone { didSet { Prefs.timeZone = timeZoneID } }
    var naiveDates: NaiveDates = Prefs.naiveDates { didSet { Prefs.naiveDates = naiveDates } }
    var radarFolders: Set<Folder> = Prefs.radarFolders { didSet { Prefs.radarFolders = radarFolders } }
    var dimOffRadar: Bool = Prefs.dimOffRadar { didSet { Prefs.dimOffRadar = dimOffRadar } }
    var reopenLast: Bool = Prefs.reopenLast { didSet { Prefs.reopenLast = reopenLast } }

    var performanceAccount: String?
    var performancePeriod: FlowPeriod = .monthly

    @ObservationIgnored private let loader = RecordLoader()
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var hasLoaded = false
    /// Selected after a reload when the selection has left the list.
    @ObservationIgnored private var fallbackSelection: String?

    init() {}

    // MARK: Derived state

    var dates: DateFormatting {
        let zone = timeZoneID.isEmpty ? TimeZone.current : (TimeZone(identifier: timeZoneID) ?? .current)
        return DateFormatting(style: dateStyle, zone: zone, naive: naiveDates)
    }

    /// Today in the local zone: what ds_* stamps are written with.
    var today: Day { Day.today() }

    var windowTitle: String { workspace?.root.lastPathComponent ?? "QDVC GTD EML" }

    var statusLine: String {
        guard workspace != nil else { return "" }
        if let statusMessage { return statusMessage }
        let input = overview.counts[.input] ?? 0
        var parts = ["\(overview.total) emails"]
        if input > 0 { parts.append("\(input) in Input") }
        if needsDateReview { parts.append("date stamps need review") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// True when workflow_autofix has something to say.
    var needsDateReview: Bool { !autofix.fixes.isEmpty || !autofix.blockers.isEmpty }

    var selectedRecords: [EmailRecord] {
        visibleRecords.filter { selection.contains($0.id) }
    }

    /// The single selected email, if exactly one is selected.
    var selectedRecord: EmailRecord? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return recordsByID[id]
    }

    var projects: [String] { overview.projects.map(\.name) }

    func record(_ id: String?) -> EmailRecord? { id.flatMap { recordsByID[$0] } }

    func isOnRadar(_ r: EmailRecord) -> Bool { radarFolders.contains(r.folder) }

    /// The emails a sidebar entry lists (before search and sorting).
    func members(of item: SidebarItem) -> [EmailRecord] {
        switch item {
        case .dashboard, .performance:
            return []
        case .folder(let f):
            return records.filter { $0.folder == f }
        case .dueSet:
            return records.filter { isOnRadar($0) && !$0.dueDate.isEmpty }
        case .noDue:
            return records.filter { isOnRadar($0) && $0.dueDate.isEmpty }
        case .pinned:
            return records.filter { isOnRadar($0) && $0.isPinned }
        case .hashtag(let tag):
            return records.filter { isOnRadar($0) && $0.mentions(tag) }
        // The account views cover every folder, regardless of the radar.
        case .inbox(let account):
            return records.filter { r in
                account == nil ? !r.inboxAccounts.isEmpty : r.inboxAccounts.contains { $0.emailAddress == account }
            }
        case .sent(let account):
            return records.filter { r in
                account == nil ? !r.sentAccounts.isEmpty : r.sentAccounts.contains { $0.emailAddress == account }
            }
        case .attention(let key):
            let ids = Set(overview.attention.first { $0.key == key }?.ids ?? [])
            return records.filter { ids.contains($0.id) }
        case .project(let name):
            return records.filter { $0.project == name }
        }
    }

    func count(_ item: SidebarItem) -> Int {
        if case .folder(let f) = item { return overview.counts[f] ?? 0 }
        return members(of: item).count
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What the message list shows: search results across every folder, or
    /// the sidebar entry's emails, sorted.
    var visibleRecords: [EmailRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [EmailRecord]
        if !query.isEmpty {
            base = records.filter { $0.searchText.contains(query) }
        } else if let item = sidebarSelection {
            base = members(of: item)
        } else {
            base = []
        }
        return sorted(base)
    }

    private func sorted(_ list: [EmailRecord]) -> [EmailRecord] {
        let key = sortKey
        let ascending = sortAscending
        func compare(_ a: EmailRecord, _ b: EmailRecord) -> ComparisonResult {
            switch key {
            case .date:
                return a.date.epoch == b.date.epoch ? .orderedSame : (a.date.epoch < b.date.epoch ? .orderedAscending : .orderedDescending)
            case .correspondent:
                return a.listCorrespondent.localizedCaseInsensitiveCompare(b.listCorrespondent)
            case .subject:
                return a.subject.localizedCaseInsensitiveCompare(b.subject)
            case .due:
                // Real dates first, then free text, then none.
                func rank(_ r: EmailRecord) -> String {
                    if let d = r.dueDay { return "0" + d.iso }
                    return r.dueDate.isEmpty ? "2" : "1" + r.dueDate.lowercased()
                }
                return rank(a).compare(rank(b))
            case .folder:
                return a.folder.number == b.folder.number ? .orderedSame
                    : (a.folder.number < b.folder.number ? .orderedAscending : .orderedDescending)
            }
        }
        return list.sorted { a, b in
            let order = compare(a, b)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            if a.date.epoch != b.date.epoch { return a.date.epoch > b.date.epoch }
            return a.id < b.id
        }
    }

    /// The list, split under date headings when sorted by date.
    var listGroups: [ListGroup] {
        let list = visibleRecords
        guard showDateHeadings, sortKey == .date else { return [ListGroup(title: "", records: list)] }
        let fmt = dates
        let today = fmt.today
        var groups: [ListGroup] = []
        for r in list {
            let title = DateBucket.title(for: fmt.day(r.date.date), today: today, monthName: DateFormatting.monthName)
            if groups.last?.title == title {
                groups[groups.count - 1].records.append(r)
            } else {
                groups.append(ListGroup(title: title, records: [r]))
            }
        }
        return groups
    }

    var listTitle: String {
        if isSearching { return "Search Results" }
        guard let item = sidebarSelection else { return "" }
        return title(for: item)
    }

    func title(for item: SidebarItem) -> String {
        switch item {
        case .dashboard: return "Dashboard"
        case .performance: return "Performance"
        case .folder(let f): return f.title
        case .dueSet: return "Due Date Set"
        case .noDue: return "No Due Date"
        case .pinned: return "Pinned"
        case .hashtag(let tag): return tag
        case .inbox(let a): return a.flatMap { accountName($0) }.map { "Inbox \u{2014} \($0)" } ?? "Inbox"
        case .sent(let a): return a.flatMap { accountName($0) }.map { "Sent \u{2014} \($0)" } ?? "Sent"
        case .attention(let key): return overview.attention.first { $0.key == key }.map { $0.label.capitalizedFirst } ?? key
        case .project(let name): return "Project: \(name)"
        }
    }

    func accountName(_ email: String) -> String? {
        config.myOwnAccounts.first { $0.emailAddress == email }?.displayName
    }

    /// Metrics for the Performance view, narrowed to one account if chosen.
    var performanceMetrics: [EmailMetrics] {
        guard let account = performanceAccount else { return metrics }
        let names = Set(records.filter { $0.tracked && $0.account?.emailAddress == account }.map(\.filename))
        return metrics.filter { names.contains($0.filename) }
    }

    // MARK: Opening

    func startUp() {
        guard workspace == nil else { return }
        if reopenLast, let last = Prefs.lastWorkspace, directoryExists(URL(fileURLWithPath: last)) {
            open(URL(fileURLWithPath: last, isDirectory: true))
        }
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a gtd-eml working directory (the folder containing 01-input \u{2026} 06-archive)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        let root = url.standardizedFileURL
        guard directoryExists(root) else {
            alert = AlertInfo(title: "Folder Not Found", message: "\(root.path) no longer exists.")
            recentWorkspaces.removeAll { $0 == root.path }
            Prefs.recentWorkspaces = recentWorkspaces
            return
        }
        let ws = Workspace(root: root)
        if !Workspace.looksLikeWorkspace(root) {
            let confirm = NSAlert()
            confirm.messageText = "Create a GTD workspace here?"
            confirm.informativeText = "\(root.path) has no workflow folders yet. QDVC GTD EML can create 01-input \u{2026} 06-archive in it, as `gtd list` would."
            confirm.addButton(withTitle: "Create Folders")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try ws.ensureFolders()
        } catch {
            alert = AlertInfo(title: "Could Not Create Folders", message: error.localizedDescription)
            return
        }
        activeSheet = nil
        editingAnnotationsID = nil
        selection = []
        searchText = ""
        records = []
        recordsByID = [:]
        hasLoaded = false
        loader.clear()
        workspace = ws
        loadConfig()
        recentWorkspaces.removeAll { $0 == root.path }
        recentWorkspaces.insert(root.path, at: 0)
        Prefs.recentWorkspaces = recentWorkspaces
        Prefs.lastWorkspace = root.path
        sidebarSelection = .folder(.triage)
        reload()
    }

    func closeWorkspace() {
        activeSheet = nil
        workspace = nil
        records = []
        recordsByID = [:]
        metrics = []
        overview = Overview([])
        selection = []
        Prefs.lastWorkspace = nil
    }

    func clearRecents() {
        recentWorkspaces = []
        Prefs.recentWorkspaces = []
    }

    private func loadConfig() {
        guard let ws = workspace else { return }
        do {
            config = try WorkspaceConfig.load(root: ws.root)
            configError = nil
        } catch {
            config = WorkspaceConfig()
            configError = error.localizedDescription
        }
        if let account = performanceAccount, !config.myOwnAccounts.contains(where: { $0.emailAddress == account }) {
            performanceAccount = nil
        }
    }

    /// Re-read workspace.yml and every changed file.
    func refresh() {
        loadConfig()
        reload()
    }

    func appBecameActive() {
        guard workspace != nil, activeSheet == nil else { return }
        refresh()
    }

    /// Reload from disk in the background, then select `select` (or keep the
    /// current selection where it still exists).
    func reload(select: Set<String>? = nil) {
        guard let ws = workspace else { return }
        loadGeneration += 1
        let generation = loadGeneration
        if !hasLoaded { isLoading = true }
        let config = self.config
        let loader = self.loader
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                loader.load(ws, config: config)
            }.value
            guard let self, generation == self.loadGeneration, self.workspace === ws else { return }
            self.apply(snapshot, select: select)
        }
    }

    private func apply(_ snapshot: WorkspaceSnapshot, select: Set<String>?) {
        records = snapshot.records
        var byID: [String: EmailRecord] = [:]
        for r in snapshot.records { byID[r.id] = r }
        recordsByID = byID
        metrics = snapshot.metrics
        autofix = snapshot.autofix
        metadataRows = snapshot.metadataRows
        overview = Overview(snapshot.records)
        isLoading = false
        hasLoaded = true
        let visible = Set(visibleRecords.map(\.id))
        var wanted = (select ?? selection).filter { visible.contains($0) }
        if wanted.isEmpty, let fallback = fallbackSelection, visible.contains(fallback) { wanted = [fallback] }
        fallbackSelection = nil
        if wanted != selection { selection = wanted }
    }

    private func keepSelectionVisible() {
        let visible = Set(visibleRecords.map(\.id))
        let kept = selection.filter { visible.contains($0) }
        if kept != selection { selection = kept }
    }

    /// The row after (or before) the given ones, for keeping a selection
    /// when emails leave the list, as Mail does.
    private func neighbour(of ids: Set<String>) -> String? {
        let list = visibleRecords.map(\.id)
        guard let last = list.lastIndex(where: { ids.contains($0) }) else { return nil }
        if let next = list[(last + 1)...].first(where: { !ids.contains($0) }) { return next }
        return list[..<last].last(where: { !ids.contains($0) })
    }

    private func flash(_ message: String) {
        statusMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.statusMessage == message { self?.statusMessage = nil }
        }
    }

    private func fail(_ title: String, _ error: Error) {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }

    // MARK: Ingest and adding files

    var inputCount: Int { overview.counts[.input] ?? 0 }

    func ingest() {
        guard let ws = workspace else { return }
        do {
            let moved = try ws.ingest(maxFilenameChars: config.maxFilenameChars)
            if moved.isEmpty {
                flash("No new files in 01-input.")
            } else {
                flash("Ingested \(moved.count) email\(moved.count == 1 ? "" : "s") into Triage.")
                let ids = Set(moved.map { Folder.triage.rawValue + "/" + $0.newName })
                if sidebarSelection == .folder(.input) || sidebarSelection == .attention("input") {
                    sidebarSelection = .folder(.triage)
                }
                reload(select: ids)
                return
            }
        } catch {
            fail("Could Not Ingest", error)
        }
        reload()
    }

    func importFiles(_ urls: [URL]) {
        guard let ws = workspace else { return }
        let emls = urls.filter { $0.pathExtension.lowercased() == "eml" }
        guard !emls.isEmpty else {
            alert = AlertInfo(title: "Nothing to Add", message: "Only .eml files can be added to Input.")
            return
        }
        do {
            let added = try ws.importToInput(emls)
            flash("Added \(added.count) to Input \u{2014} Ingest (\u{21E7}\u{2318}N) to file \(added.count == 1 ? "it" : "them").")
        } catch {
            fail("Could Not Add Files", error)
        }
        reload()
    }

    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let eml = UTType(filenameExtension: "eml") { panel.allowedContentTypes = [eml] }
        panel.prompt = "Add to Input"
        panel.message = "Choose .eml files to copy into 01-input."
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    // MARK: Workflow actions

    /// Why an email cannot be moved to `dest`, or nil if it can.
    func moveRefusal(_ r: EmailRecord, to dest: Folder) -> String? {
        if r.folder == .input { return "Ingest it first" }
        if r.folder == dest { return "Already here" }
        if dest == .input { return "Emails are never returned to Input" }
        guard let ws = workspace else { return "No workspace" }
        if let field = dest.stampField, let value = metadataRows[r.filename]?[field], !value.isEmpty {
            return "Already has \(field) = \(value)"
        }
        return ws.allocRefusal(r.filename, to: dest, metadata: metadataRows)?.message
    }

    func canMove(_ ids: [String], to dest: Folder) -> Bool {
        ids.contains { id in record(id).map { moveRefusal($0, to: dest) == nil } ?? false }
    }

    func move(_ ids: [String], to dest: Folder) {
        guard let ws = workspace else { return }
        var refusals: [String] = []
        var newIDs = Set<String>()
        fallbackSelection = neighbour(of: Set(ids))
        for id in ids {
            guard let r = record(id) else { continue }
            if r.folder == .input {
                refusals.append("'\(r.filename)' is still in 01-input; ingest it first.")
                continue
            }
            do {
                try ws.alloc(r.filename, to: dest)
                newIDs.insert(dest.rawValue + "/" + r.filename)
            } catch {
                refusals.append(error.localizedDescription)
            }
        }
        if !newIDs.isEmpty { flash("Moved \(newIDs.count) to \(dest.title).") }
        reload(select: newIDs)
        if !refusals.isEmpty {
            alert = AlertInfo(title: refusals.count == 1 ? "Could Not Move Email" : "Some Emails Were Not Moved",
                              message: refusals.joined(separator: "\n\n"))
        }
    }

    func closeRefusal(_ r: EmailRecord) -> String? {
        if r.folder == .input { return "Ingest it first" }
        return workspace?.closeRefusal(r.filename, metadata: metadataRows)?.message
    }

    func beginClose(_ id: String?) {
        guard let r = record(id) else { return }
        if let refusal = closeRefusal(r) {
            alert = AlertInfo(title: "Cannot Close This Email", message: refusal)
            return
        }
        activeSheet = .closeWith(r.id)
    }

    func close(_ id: String, with otherID: String) {
        guard let ws = workspace, let r = record(id), let other = record(otherID) else { return }
        fallbackSelection = neighbour(of: [id])
        do {
            try ws.close(r.filename, with: other.filename)
            flash("Closed with \(other.filename).")
            reload(select: [Folder.archive.rawValue + "/" + r.filename])
        } catch {
            fail("Could Not Close Email", error)
            reload()
        }
    }

    func annotationsRefusal(_ r: EmailRecord) -> String? {
        r.folder == .input ? "Ingest it first: ingestion renames the file, so annotations would be lost." : nil
    }

    func togglePin(_ ids: [String]) {
        guard let ws = workspace else { return }
        let targets = ids.compactMap { record($0) }.filter { $0.folder != .input }
        guard !targets.isEmpty else { return }
        let pin = !targets.allSatisfy(\.isPinned)
        do {
            for r in targets { try ws.setFlag(r.filename, "pinned", on: pin) }
        } catch {
            fail(pin ? "Could Not Pin" : "Could Not Unpin", error)
        }
        reload()
    }

    func beginEdit(_ id: String?) {
        guard let r = record(id) else { return }
        if let refusal = annotationsRefusal(r) {
            alert = AlertInfo(title: "Cannot Edit Annotations", message: refusal)
            return
        }
        selection = [r.id]
        editingAnnotationsID = r.id
    }

    /// Write only the fields that changed. Returns true on success.
    @discardableResult
    func saveAnnotations(_ id: String, _ values: [String: String]) -> Bool {
        guard let ws = workspace, let r = record(id) else { return false }
        var changes: [String: String] = [:]
        for (field, value) in values where (r.row[field] ?? "") != value { changes[field] = value }
        guard !changes.isEmpty else {
            editingAnnotationsID = nil
            return true
        }
        do {
            let warnings = try ws.setFields(r.filename, changes)
            editingAnnotationsID = nil
            reload()
            if !warnings.isEmpty {
                alert = AlertInfo(title: "Saved, With a Warning", message: warnings.joined(separator: "\n"))
            }
            return true
        } catch {
            fail("Could Not Save Annotations", error)
            return false
        }
    }

    func beginReviewDateStamps() {
        guard let ws = workspace else { return }
        autofix = ws.planAutofix()
        activeSheet = .reviewDateStamps
    }

    func applyAutofix() {
        guard let ws = workspace else { return }
        let fresh = ws.planAutofix()
        guard fresh == autofix else {
            autofix = fresh
            alert = AlertInfo(title: "The Workspace Changed",
                              message: "The date stamps changed on disk while this list was open. Review the updated list, then apply again.")
            return
        }
        do {
            try ws.applyAutofix(fresh)
            activeSheet = nil
            flash("Applied \(fresh.fixes.count) date stamp\(fresh.fixes.count == 1 ? "" : "s").")
        } catch {
            fail("Could Not Apply Date Stamps", error)
        }
        reload()
    }

    func beginCheckMetadata() {
        guard let ws = workspace else { return }
        activeSheet = .checkMetadata(ws.previewMetadataCheck())
    }

    func reconcileMetadata() {
        guard let ws = workspace else { return }
        do {
            try ws.metadataCheck()
            activeSheet = nil
            flash("metadata.csv reconciled with the files on disk.")
        } catch {
            fail("Could Not Reconcile metadata.csv", error)
        }
        reload()
    }

    // MARK: Files

    func fileURL(_ r: EmailRecord) -> URL? { workspace?.url(r.folder, r.filename) }

    func openInMail(_ ids: [String]) {
        for id in ids.prefix(10) {
            if let r = record(id), let url = fileURL(r) { Platform.open(url) }
        }
    }

    func quickLook(_ id: String?) {
        guard let r = record(id), let url = fileURL(r) else { return }
        quickLookURL = url
    }

    func revealInFinder(_ ids: [String]) {
        let urls = ids.compactMap { id in record(id).flatMap { fileURL($0) } }
        if !urls.isEmpty { Platform.reveal(urls) }
    }

    func copyFilenames(_ ids: [String]) {
        let names = ids.compactMap { record($0)?.filename }
        if !names.isEmpty { Platform.copy(names.joined(separator: "\n")) }
    }

    func revealWorkspace() {
        if let root = workspace?.root { Platform.reveal([root]) }
    }

    static let exampleConfig = """
    # workspace.yml \u{2014} settings shared by the gtd CLI and QDVC GTD EML.
    max_filename_chars: 60
    green_max_days: 2
    yellow_max_days: 14
    my_own_accounts:
      - email_address: me@example.com
        display_name: "Work account"
        colour: yellow
    monitored_hashtags:
      - "#urgent"

    """

    /// Open workspace.yml in the text editor. The app never writes it.
    func openConfigFile() {
        guard let ws = workspace else { return }
        if FileManager.default.fileExists(atPath: ws.configURL.path) {
            Platform.openInTextEditor(ws.configURL)
            return
        }
        let info = NSAlert()
        info.messageText = "This workspace has no workspace.yml"
        info.informativeText = "All workspace settings are at their defaults. To change them, create \(WorkspaceConfig.fileName) at the root of the workspace (next to metadata.csv); the example can be copied to the clipboard as a starting point."
        info.addButton(withTitle: "Copy Example")
        info.addButton(withTitle: "OK")
        if info.runModal() == .alertFirstButtonReturn { Platform.copy(AppModel.exampleConfig) }
    }
}

extension String {
    /// The string with its first character upper-cased.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
