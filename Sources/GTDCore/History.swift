import Foundation

/// The history chains made by `close … with …`: an email whose next action is
/// "Closed with <file>.eml" was closed by that file, which may itself have
/// been closed by another, and so on. Several emails can be closed with the
/// same one, so a chain can branch; each email is closed by at most one.
///
/// Every email in a chain gets the whole chain, ordered so that each email
/// comes before the one that closed it (emails closed by the same one in
/// date order), ending with the latest email. A reference to a file that is
/// not in the workspace stays in the chain as a missing entry.
public struct CloseHistory {
    /// One email of a chain.
    public struct Entry: Hashable, Identifiable {
        /// The record id, or a "missing/…" key for a file not in the workspace.
        public let id: String
        public let filename: String
        /// The id of the entry that closed this one (nil for the latest).
        public let closedBy: String?

        public var isMissing: Bool { id.hasPrefix(CloseHistory.missingPrefix) }
        /// The record id, when the file is in the workspace.
        public var recordID: String? { isMissing ? nil : id }
    }

    /// What the chains are built from (one email).
    public struct Node: Hashable {
        public let id: String
        public let filename: String
        public let nextAction: String
        /// Sorts emails closed by the same one (the Date header's epoch).
        public let epoch: Int

        public init(id: String, filename: String, nextAction: String, epoch: Int) {
            self.id = id
            self.filename = filename
            self.nextAction = nextAction
            self.epoch = epoch
        }
    }

    static let missingPrefix = "missing/"
    static let closedWithRx = Rx("^\\s*closed with\\s+(\\S+?\\.eml)(?=$|[\\s,;:.)\\]])", [.caseInsensitive])

    /// The file named by a "Closed with <file>.eml" next action (as written
    /// by `close`, case-insensitive, with any text after the name), or nil.
    public static func closingReference(_ nextAction: String) -> String? {
        closedWithRx.firstMatch(nextAction)?.group(1)
    }

    private let chains: [String: [Entry]]

    public static let empty = CloseHistory(nodes: [])

    public init(_ records: [EmailRecord]) {
        self.init(nodes: records.map {
            Node(id: $0.id, filename: $0.filename, nextAction: $0.nextAction, epoch: $0.date.epoch)
        })
    }

    /// `nodes` in workflow-folder order: when a name appears in two folders,
    /// a reference goes to the first, as `find` does.
    public init(nodes: [Node]) {
        var byName: [String: Node] = [:]
        var byLowerName: [String: Node] = [:]
        for n in nodes {
            if byName[n.filename] == nil { byName[n.filename] = n }
            let lower = n.filename.lowercased()
            if byLowerName[lower] == nil { byLowerName[lower] = n }
        }

        // Each email's closer: an exact name first, then a case-insensitive
        // one (`find` matches either way on a case-insensitive volume).
        var closer: [String: String] = [:]
        var filenames: [String: String] = [:]
        var epochs: [String: Int] = [:]
        for n in nodes {
            filenames[n.id] = n.filename
            epochs[n.id] = n.epoch
            guard let ref = CloseHistory.closingReference(n.nextAction) else { continue }
            if let target = byName[ref] ?? byLowerName[ref.lowercased()] {
                if target.id != n.id { closer[n.id] = target.id }
            } else {
                let key = CloseHistory.missingPrefix + ref
                closer[n.id] = key
                filenames[key] = filenames[key] ?? ref
            }
        }

        // Connected components (union-find over the closing links).
        var parent: [String: String] = [:]
        func root(_ k: String) -> String {
            var k = k
            while let p = parent[k], p != k {
                parent[k] = parent[p] ?? p
                k = p
            }
            return k
        }
        for (from, to) in closer {
            parent[from] = parent[from] ?? from
            parent[to] = parent[to] ?? to
            let a = root(from), b = root(to)
            if a != b { parent[a] = b }
        }
        var components: [String: [String]] = [:]
        for k in parent.keys { components[root(k), default: []].append(k) }

        var closedWith: [String: [String]] = [:]
        for (from, to) in closer { closedWith[to, default: []].append(from) }

        func precedes(_ a: String, _ b: String) -> Bool {
            let ea = epochs[a] ?? Int.max, eb = epochs[b] ?? Int.max
            return ea != eb ? ea < eb : a < b
        }

        var chains: [String: [Entry]] = [:]
        for members in components.values where members.count > 1 {
            // Earlier emails first, then the one that closed them; a chain
            // has one latest email unless the links go round in a loop.
            var order: [String] = []
            var seen = Set<String>()
            func visit(_ k: String) {
                guard seen.insert(k).inserted else { return }
                for earlier in (closedWith[k] ?? []).sorted(by: precedes) { visit(earlier) }
                order.append(k)
            }
            for head in members.filter({ closer[$0] == nil }).sorted(by: precedes) { visit(head) }
            order += members.filter { !seen.contains($0) }.sorted(by: precedes)

            let entries = order.map { Entry(id: $0, filename: filenames[$0] ?? $0, closedBy: closer[$0]) }
            for k in order where !k.hasPrefix(CloseHistory.missingPrefix) { chains[k] = entries }
        }
        self.chains = chains
    }

    /// The chain the email belongs to (empty when it is in none).
    public func chain(for id: String) -> [Entry] { chains[id] ?? [] }

    public func isInChain(_ id: String) -> Bool { chains[id] != nil }
}
