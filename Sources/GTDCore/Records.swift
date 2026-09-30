import Foundation

/// A ds_* stamp in the workflow trail.
public struct Stamp: Hashable {
    public let field: String
    public let label: String
    public let date: String
}

/// One email as the app shows it: the parsed `.eml` plus its metadata row,
/// the workspace settings and its metrics (`site.build_email_record`).
public struct EmailRecord: Identifiable, Hashable {
    /// "folder/filename": unique even if a name appears in two folders.
    public let id: String
    public let filename: String
    public let folder: Folder
    public let parsed: ParsedEmail
    public let row: Metadata.Row

    public let flags: [String]
    public let project: String
    public let nextAction: String
    public let dueDate: String
    public let notes: String
    public let ref: String
    public let stamps: [Stamp]
    /// "ongoing", "resolved", "weird" for tracked emails, "untracked" for 01-input.
    public let status: String
    public let metrics: [String: Int]
    public let date: EmailDate
    public let ageDays: Int?
    public let ageClass: Rules.AgeClass?
    public let account: OwnAccount?
    public let inboxAccounts: [OwnAccount]
    public let sentAccounts: [OwnAccount]
    public let correspondents: [String]
    /// Lower-cased text searched by the search field (all fields, all
    /// messages of the thread including quoted text).
    public let searchText: String

    static let stampSequence = [("ds_triage", "Triaged"), ("ds_actionable", "Actionable"),
                                ("ds_delegated", "Delegated"), ("ds_reference", "Reference"),
                                ("ds_archive", "Archived")]

    public var tracked: Bool { folder != .input }
    public var subject: String { parsed.subject.isEmpty ? "(no subject)" : parsed.subject }
    public var isPinned: Bool { flags.contains("pinned") }
    public var isUnreadable: Bool { parsed.error != nil }
    /// The due date when it is a real yyyy-mm-dd day.
    public var dueDay: Day? { Rules.isISODate(dueDate) ? Day(iso: dueDate.pyStrip) : nil }
    public var hasAttachments: Bool { !parsed.attachments.isEmpty }

    /// The correspondent shown in bold in the list (like Mail's sender column).
    public var listCorrespondent: String {
        if let first = correspondents.first { return EmailRecord.displayName(first) }
        if !parsed.fromText.isEmpty { return EmailRecord.displayName(parsed.fromText) }
        return "(no correspondents)"
    }

    /// "Jane Doe <jane@x.com>" -> "Jane Doe"; a bare address stays as it is.
    public static func displayName(_ entry: String) -> String {
        if let lt = entry.range(of: " <", options: .backwards), entry.hasSuffix(">") {
            let name = String(entry[..<lt.lowerBound]).pyStrip
            return name.isEmpty ? entry : name
        }
        return entry
    }

    public init(folder: Folder, filename: String, parsed: ParsedEmail, row: Metadata.Row?,
                config: WorkspaceConfig, metrics computed: EmailMetrics?, todayUTC: Day, now: Date) {
        id = folder.rawValue + "/" + filename
        self.filename = filename
        self.folder = folder
        self.parsed = parsed
        let meta = row ?? [:]
        self.row = meta
        func value(_ key: String) -> String { (meta[key] ?? "").pyStrip }
        flags = Rules.parseFlags(meta["flags"] ?? "").sorted(by: codePointPrecedes)
        project = value("project")
        nextAction = value("next_action")
        dueDate = value("due_date")
        notes = value("general_notes")
        ref = value("message_ref")
        stamps = EmailRecord.stampSequence.compactMap { pair -> Stamp? in
            let d = value(pair.0)
            return d.isEmpty ? nil : Stamp(field: pair.0, label: pair.1, date: d)
        }
        if let computed {
            status = computed.status.rawValue
            metrics = computed.metrics
        } else {
            status = folder == .input ? "untracked" : ""
            metrics = [:]
        }
        date = parsed.effectiveDate(now: now)
        if parsed.error == nil {
            let age = todayUTC.days(since: date.day)
            ageDays = age
            ageClass = Rules.ageClass(days: age, greenMax: config.greenMaxDays, yellowMax: config.yellowMaxDays)
        } else {
            ageDays = nil
            ageClass = nil
        }
        account = parsed.ownAccount(config.myOwnAccounts)
        let roles = parsed.ownAccountsByRole(config.myOwnAccounts)
        inboxAccounts = roles.recipient
        sentAccounts = roles.sender
        correspondents = parsed.correspondents(excluding: config.myOwnAccounts)

        var haystack = [filename, parsed.subject, parsed.fromText, parsed.toText, parsed.ccText, parsed.bccText,
                        project, nextAction, dueDate, notes, ref, flags.joined(separator: " "), parsed.body]
        haystack += parsed.attachments
        haystack += correspondents
        searchText = haystack.joined(separator: "\n").lowercased()
    }

    /// `due_date` is before today (only for real dates).
    public func isOverdue(today: Day) -> Bool {
        guard let due = dueDay else { return false }
        return due < today
    }

    /// Case-insensitive substring match on `next_action` (a hashtag view).
    public func mentions(_ tag: String) -> Bool {
        !tag.isEmpty && nextAction.lowercased().contains(tag.lowercased())
    }
}

/// The overview's "needs attention" figures (`site.build_overview`).
public struct Overview: Hashable {
    public struct Figure: Hashable, Identifiable {
        public let key: String
        public let label: String
        public let hint: String
        public let ids: [String]
        public var id: String { key }
        public var count: Int { ids.count }
    }

    public struct Project: Hashable, Identifiable {
        public let name: String
        public let ids: [String]
        public var id: String { name }
    }

    public let counts: [Folder: Int]
    public let tracked: Int
    public let total: Int
    public let statuses: [String: Int]
    public let attention: [Figure]
    public let projects: [Project]

    public init(_ emails: [EmailRecord]) {
        var counts: [Folder: Int] = [:]
        for f in Folder.allCases { counts[f] = 0 }
        for e in emails { counts[e.folder, default: 0] += 1 }
        self.counts = counts
        tracked = emails.filter(\.tracked).count
        total = emails.count
        var statuses: [String: Int] = [:]
        for e in emails { statuses[e.status.isEmpty ? "untracked" : e.status, default: 0] += 1 }
        self.statuses = statuses

        func ids(_ predicate: (EmailRecord) -> Bool) -> [String] { emails.filter(predicate).map(\.id) }
        let stale = Rules.staleThresholdDays
        attention = [
            Figure(key: "input", label: "awaiting ingestion in 01-input",
                   hint: "Ingest them (\u{21E7}\u{2318}N) to rename and file them into Triage.",
                   ids: ids { $0.folder == .input }),
            Figure(key: "stale", label: "open longer than \(stale) days",
                   hint: "Still unresolved and aging \u{2014} decide, delegate, or archive.",
                   ids: ids { $0.tracked && $0.status == "ongoing" && ($0.ageDays ?? 0) > stale }),
            Figure(key: "no-action", label: "no next action recorded",
                   hint: "An open email with no next action is where a GTD system leaks.",
                   ids: ids { $0.folder.isOpen && $0.nextAction.isEmpty }),
            Figure(key: "no-due", label: "no due date set",
                   hint: "Only counts the open folders \u{2014} reference and archive rarely need one.",
                   ids: ids { $0.folder.isOpen && $0.dueDate.isEmpty }),
            Figure(key: "pinned", label: "pinned", hint: "Pinned for your attention.",
                   ids: ids { $0.isPinned }),
            Figure(key: "weird", label: "inconsistent date progression",
                   hint: "Excluded from every performance metric until the stamps make sense.",
                   ids: ids { $0.status == "weird" }),
            Figure(key: "unreadable", label: "could not be parsed",
                   hint: "The .eml file itself could not be read.",
                   ids: ids { $0.isUnreadable }),
        ]
        var byProject: [String: [String]] = [:]
        for e in emails where !e.project.isEmpty { byProject[e.project, default: []].append(e.id) }
        projects = byProject.map { Project(name: $0.key, ids: $0.value) }.sorted {
            $0.ids.count != $1.ids.count ? $0.ids.count > $1.ids.count
                : codePointPrecedes($0.name.lowercased(), $1.name.lowercased())
        }
    }
}

/// The date headings of the message list (newest first).
public enum DateBucket {
    /// The heading for an email received on `day` when today is `today`.
    public static func title(for day: Day, today: Day, monthName: (Int) -> String) -> String {
        if day >= today { return "Today" }
        if day == today.adding(days: -1) { return "Yesterday" }
        let weekStart = today.adding(days: -today.weekday)
        if day >= weekStart { return "This Week" }
        if day >= weekStart.adding(days: -7) { return "Last Week" }
        let monthStart = Day(year: today.year, month: today.month, day: 1)
        if day >= monthStart { return "Earlier This Month" }
        let lastMonthStart = today.month == 1 ? Day(year: today.year - 1, month: 12, day: 1)
            : Day(year: today.year, month: today.month - 1, day: 1)
        if day >= lastMonthStart { return "Last Month" }
        if day.year == today.year { return monthName(day.month) }
        return String(day.year)
    }
}

/// Loads every email of a workspace, reusing parses of unchanged files.
public final class RecordLoader {
    private struct CacheKey: Hashable {
        let filename: String
        let size: Int
        let modified: TimeInterval
    }

    private var cache: [CacheKey: ParsedEmail] = [:]
    private let lock = NSLock()

    public init() {}

    public func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// Parse (or fetch from cache) the email at `url`. The key survives a
    /// move between folders, since moving keeps size and modification date.
    public func parsed(_ url: URL) -> ParsedEmail {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = CacheKey(filename: url.lastPathComponent, size: size, modified: modified)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let parsed = ParsedEmail.load(url)
        lock.lock()
        cache[key] = parsed
        lock.unlock()
        return parsed
    }

    /// Everything the window shows, built from disk.
    public func load(_ workspace: Workspace, config: WorkspaceConfig, now: Date = Date()) -> WorkspaceSnapshot {
        let metadata = workspace.loadMetadata()
        let todayUTC = Day.today(in: TimeZone(identifier: "UTC")!, now: now)
        var records: [EmailRecord] = []
        var computed: [EmailMetrics] = []
        for folder in Folder.allCases {
            var folderRecords: [EmailRecord] = []
            for name in workspace.listEML(folder) {
                let parsed = self.parsed(workspace.url(folder, name))
                var metrics: EmailMetrics?
                if folder != .input {
                    let m = Analytics.computeMetrics(filename: name, row: metadata[name] ?? [:])
                    metrics = m
                    computed.append(m)
                }
                folderRecords.append(EmailRecord(folder: folder, filename: name, parsed: parsed,
                                                 row: metadata[name], config: config, metrics: metrics,
                                                 todayUTC: todayUTC, now: now))
            }
            records += folderRecords
        }
        let plan = workspace.planAutofix(metadata: metadata)
        return WorkspaceSnapshot(records: records, metrics: computed, autofix: plan, metadataRows: metadata)
    }
}

/// One load of the workspace.
public struct WorkspaceSnapshot {
    public let records: [EmailRecord]
    /// Metrics of the tracked emails (for the Performance view).
    public let metrics: [EmailMetrics]
    public let autofix: AutofixPlan
    public let metadataRows: [String: Metadata.Row]
}
