import Foundation
import GTDCore

/// How dates are written (the web UI's `dateFormat` setting).
enum DateStyle: String, CaseIterable, Identifiable {
    case long, medium, iso
    var id: String { rawValue }

    var example: String {
        switch self {
        case .long: return "Tuesday, 3 August 2026 12:34"
        case .medium: return "3 Aug 2026 12:34"
        case .iso: return "2026-08-03 12:34"
        }
    }
}

/// How to read a quoted header's time that names no zone.
enum NaiveDates: String, CaseIterable, Identifiable {
    case local, utc
    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "As written"
        case .utc: return "As UTC, converted"
        }
    }
}

/// Reader preferences, in the standard defaults domain
/// (`defaults read org.qdvc.gtdeml.mac`). Workspace settings live in the
/// workspace's own `workspace.yml` instead, so the CLI sees them too.
enum Prefs {
    enum Key {
        static let recentWorkspaces = "recentWorkspaces"
        static let lastWorkspace = "lastWorkspace"
        static let reopenLast = "reopenLastWorkspace"
        static let dateStyle = "dateStyle"
        static let timeZone = "timeZone"
        static let naiveDates = "naiveDates"
        static let radarFolders = "radarFolders"
        static let dimOffRadar = "dimOffRadar"
        static let dateHeadings = "showDateHeadings"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
    }

    private static var defaults: UserDefaults { .standard }

    static var recentWorkspaces: [String] {
        get { defaults.stringArray(forKey: Key.recentWorkspaces) ?? [] }
        set { defaults.set(Array(newValue.prefix(10)), forKey: Key.recentWorkspaces) }
    }

    static var lastWorkspace: String? {
        get { defaults.string(forKey: Key.lastWorkspace) }
        set { defaults.set(newValue, forKey: Key.lastWorkspace) }
    }

    static var reopenLast: Bool {
        get { defaults.object(forKey: Key.reopenLast) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.reopenLast) }
    }

    static var dateStyle: DateStyle {
        get { DateStyle(rawValue: defaults.string(forKey: Key.dateStyle) ?? "") ?? .long }
        set { defaults.set(newValue.rawValue, forKey: Key.dateStyle) }
    }

    /// An IANA zone name, or "" for the system's.
    static var timeZone: String {
        get { defaults.string(forKey: Key.timeZone) ?? "" }
        set { defaults.set(newValue, forKey: Key.timeZone) }
    }

    static var naiveDates: NaiveDates {
        get { NaiveDates(rawValue: defaults.string(forKey: Key.naiveDates) ?? "") ?? .local }
        set { defaults.set(newValue.rawValue, forKey: Key.naiveDates) }
    }

    static let defaultRadar: [Folder] = [.input, .triage, .actionable, .delegated]

    /// The folders the smart mailboxes and account views cover.
    static var radarFolders: Set<Folder> {
        get {
            guard let raw = defaults.stringArray(forKey: Key.radarFolders) else { return Set(defaultRadar) }
            return Set(raw.compactMap(Folder.init(rawValue:)))
        }
        set { defaults.set(Folder.allCases.filter(newValue.contains).map(\.rawValue), forKey: Key.radarFolders) }
    }

    static var dimOffRadar: Bool {
        get { defaults.object(forKey: Key.dimOffRadar) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.dimOffRadar) }
    }

    static var dateHeadings: Bool {
        get { defaults.object(forKey: Key.dateHeadings) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.dateHeadings) }
    }

    static var sortKey: SortKey {
        get { SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .date }
        set { defaults.set(newValue.rawValue, forKey: Key.sortKey) }
    }

    static var sortAscending: Bool {
        get { defaults.object(forKey: Key.sortAscending) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.sortAscending) }
    }
}
