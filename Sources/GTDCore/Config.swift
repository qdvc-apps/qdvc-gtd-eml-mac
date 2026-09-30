import Foundation
import Yams

/// The six workflow folders, in workflow order.
public enum Folder: String, CaseIterable, Identifiable, Hashable, Codable {
    case input = "01-input"
    case triage = "02-triage"
    case actionable = "03-actionable"
    case delegated = "04-delegated"
    case reference = "05-reference"
    case archive = "06-archive"

    public var id: String { rawValue }

    /// The `gtd alloc` alias, also used as a stable key.
    public var alias: String {
        switch self {
        case .input: return "input"
        case .triage: return "triage"
        case .actionable: return "actionable"
        case .delegated: return "delegated"
        case .reference: return "reference"
        case .archive: return "archive"
        }
    }

    public var title: String {
        switch self {
        case .input: return "Input"
        case .triage: return "Triage"
        case .actionable: return "Actionable"
        case .delegated: return "Delegated"
        case .reference: return "Reference"
        case .archive: return "Archive"
        }
    }

    /// 1…6, as in the folder names.
    public var number: Int { (Folder.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The ds_* column stamped when an email arrives here (none for input).
    public var stampField: String? {
        switch self {
        case .input: return nil
        case .triage: return "ds_triage"
        case .actionable: return "ds_actionable"
        case .delegated: return "ds_delegated"
        case .reference: return "ds_reference"
        case .archive: return "ds_archive"
        }
    }

    /// Emails in these folders are open work (the overview's "open" folders).
    public var isOpen: Bool { self == .triage || self == .actionable || self == .delegated }

    /// `fs.resolve_folder`: an alias or full folder name, case-insensitively.
    public init?(resolving name: String) {
        let key = name.pyStrip.lowercased()
        if let f = Folder.allCases.first(where: { $0.alias == key || $0.rawValue == key }) {
            self = f
        } else {
            return nil
        }
    }
}

/// One of `my_own_accounts`, normalised.
public struct OwnAccount: Hashable, Codable, Identifiable {
    public let emailAddress: String
    public let displayName: String
    /// One of green, yellow, red, blue, magenta, cyan.
    public let colour: String

    public var id: String { emailAddress }

    public init(emailAddress: String, displayName: String, colour: String) {
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.colour = colour
    }
}

/// The workspace's own settings, read from `<workspace>/workspace.yml` (see
/// docs/WORKSPACE_CONFIG_REQUEST.md). Every key is optional.
public struct WorkspaceConfig: Hashable {
    public static let fileName = "workspace.yml"
    public static let colours: Set<String> = ["green", "yellow", "red", "blue", "magenta", "cyan"]

    public var myOwnAccounts: [OwnAccount] = []
    public var monitoredHashtags: [String] = []
    public var greenMaxDays = 2
    public var yellowMaxDays = 14
    public var maxFilenameChars = 60

    public init() {}

    /// Load the workspace's settings. A missing file gives the defaults; a
    /// file that cannot be parsed, or is not a mapping, throws.
    public static func load(root: URL) throws -> WorkspaceConfig {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkspaceConfig() }
        let text = readTextFile(url) ?? ""
        return try parse(text, fileName: url.path)
    }

    public struct ConfigError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func parse(_ text: String, fileName: String = WorkspaceConfig.fileName) throws -> WorkspaceConfig {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw ConfigError(message: "\(fileName) could not be read as YAML: \(error)")
        }
        var config = WorkspaceConfig()
        guard let node else { return config }  // an empty file
        let loaded = convert(node)
        if loaded is NSNull { return config }
        guard let map = loaded as? [String: Any] else {
            throw ConfigError(message: "\(fileName) must be a YAML mapping of settings.")
        }
        if let value = map["my_own_accounts"], !(value is NSNull) {
            config.myOwnAccounts = normaliseAccounts(value)
        }
        if let value = map["monitored_hashtags"], !(value is NSNull) {
            config.monitoredHashtags = normaliseHashtags(value)
        }
        if let n = intValue(map["green_max_days"]) { config.greenMaxDays = n }
        if let n = intValue(map["yellow_max_days"]) { config.yellowMaxDays = n }
        if let n = intValue(map["max_filename_chars"]) { config.maxFilenameChars = n }
        return config
    }

    /// A YAML node as plain values, the way PyYAML's `safe_load` types them
    /// (for the shapes this file uses).
    static func convert(_ node: Node) -> Any {
        switch node {
        case .scalar(let scalar):
            let tag = node.tag.description
            if tag == Tag.Name.str.rawValue { return scalar.string }
            if tag == Tag.Name.null.rawValue { return NSNull() }
            if tag == Tag.Name.bool.rawValue, let b = node.bool { return b }
            if tag == Tag.Name.int.rawValue, let i = node.int { return i }
            return scalar.string
        case .mapping(let mapping):
            var dict: [String: Any] = [:]
            for (key, value) in mapping { dict[key.scalar?.string ?? ""] = convert(value) }
            return dict
        case .sequence(let sequence):
            return sequence.map { convert($0) }
        default:
            return NSNull()
        }
    }

    static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let s = value as? String { return Int(s.pyStrip) }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? Int { return String(n) }
        return nil
    }

    /// `config.normalise_accounts`.
    public static func normaliseAccounts(_ raw: Any) -> [OwnAccount] {
        guard let list = raw as? [Any] else { return [] }
        var result: [OwnAccount] = []
        for entry in list {
            guard let dict = entry as? [String: Any] else { continue }
            let email = (stringValue(dict["email_address"]) ?? "").pyStrip.lowercased()
            if email.isEmpty { continue }
            var colour = (stringValue(dict["colour"]).flatMap { $0.isEmpty ? nil : $0 } ?? "cyan").pyStrip.lowercased()
            if !colours.contains(colour) { colour = "cyan" }
            let name = (stringValue(dict["display_name"]).flatMap { $0.isEmpty ? nil : $0 } ?? email).pyStrip
            result.append(OwnAccount(emailAddress: email, displayName: name, colour: colour))
        }
        return result
    }

    /// `config.normalise_hashtags`.
    public static func normaliseHashtags(_ raw: Any) -> [String] {
        guard let list = raw as? [Any] else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        for entry in list {
            guard let s = entry as? String else { continue }
            let tag = s.pyStrip
            if tag.isEmpty || seen.contains(tag.lowercased()) { continue }
            seen.insert(tag.lowercased())
            result.append(tag)
        }
        return result
    }
}

/// Small rules shared by the report, the web UI and this app.
public enum Rules {
    /// Ongoing emails older than this are "stale" (dashboard/site threshold).
    public static let staleThresholdDays = 14

    public enum AgeClass: String, Hashable { case green, yellow, red }

    /// `report.colour_for_days`.
    public static func ageClass(days: Int, greenMax: Int, yellowMax: Int) -> AgeClass {
        if days < greenMax { return .green }
        if days < yellowMax { return .yellow }
        return .red
    }

    static let flagSplitRx = Rx("[,\\s]+")

    /// `report.parse_flags`: lower-cased tokens split on commas/whitespace.
    public static func parseFlags(_ raw: String) -> Set<String> {
        guard !raw.isEmpty else { return [] }
        return Set(flagSplitRx.split(raw.pyStrip).filter { !$0.isEmpty }.map { $0.lowercased() })
    }

    static let tagSlugRx = Rx("[^a-z0-9]+")

    /// `site.hashtag_key`.
    public static func hashtagKey(_ tag: String, taken: Set<String> = []) -> String {
        var slug = tagSlugRx.replace(tag.lowercased(), with: "-").pyStrip(["-"])
        if slug.isEmpty { slug = "tag" }
        let key = "tag-" + slug
        guard taken.contains(key) else { return key }
        var suffix = 2
        while taken.contains("\(key)-\(suffix)") { suffix += 1 }
        return "\(key)-\(suffix)"
    }

    static let isoDateRx = Rx("^\\d{4}-\\d{2}-\\d{2}$")

    /// True for a strict yyyy-mm-dd string (the form due dates should take).
    public static func isISODate(_ value: String) -> Bool { isoDateRx.matches(value.pyStrip) }
}
