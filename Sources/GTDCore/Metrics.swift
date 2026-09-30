import Foundation

/// One tracked email for autofix planning.
public struct AutofixRecord: Hashable {
    public let filename: String
    public let folder: Folder
    public let row: Metadata.Row
}

public struct AutofixFix: Hashable, Identifiable {
    public enum Phase: String, Hashable {
        case folderConsistency = "folder-consistency"
        case dateBackfill = "date-backfill"

        public var title: String {
            switch self {
            case .folderConsistency: return "Folder/stamp consistency"
            case .dateBackfill: return "Logical-progression date backfills"
            }
        }
    }

    public let filename: String
    public let folder: Folder
    public let field: String
    public let old: String
    public let new: String
    public let phase: Phase

    public var id: String { "\(folder.rawValue)/\(filename)/\(field)" }
}

public struct AutofixBlocker: Hashable, Identifiable {
    public let filename: String
    public let folder: Folder
    public let reason: String
    public var id: String { "\(folder.rawValue)/\(filename)" }
}

/// `workflow_autofix`'s view of the workspace.
public struct AutofixPlan: Hashable {
    /// Files still in 01-input (the CLI refuses to run while there are any).
    public let pendingInput: Int
    public let fixes: [AutofixFix]
    public let blockers: [AutofixBlocker]

    public init(pendingInput: Int, fixes: [AutofixFix], blockers: [AutofixBlocker]) {
        self.pendingInput = pendingInput
        self.fixes = fixes
        self.blockers = blockers
    }

    /// True when the ds_* stamps are complete and consistent.
    public var isClean: Bool { pendingInput == 0 && fixes.isEmpty && blockers.isEmpty }
}

/// Classification and response-time metrics of one email
/// (`metrics.compute_email_metrics`).
public struct EmailMetrics: Hashable {
    public enum Status: String, Hashable { case ongoing, resolved, weird }

    public let filename: String
    public let emailDate: Day?
    public let triageDate: Day?
    public let actionableDate: Day?
    public let resolutionDate: Day?
    public let status: Status
    /// Any of "ttS", "Td", "Wd", "tttR" that apply (none for weird emails).
    public let metrics: [String: Int]
    /// (label, day) the email passed through, from "took place".
    public let stages: [Stage]

    public struct Stage: Hashable {
        public let label: String
        public let day: Day
    }
}

public struct BacklogStats: Hashable {
    public let count: Int
    public let meanAge: Double?
    public let medianAge: Double?
    public let oldestAge: Int?
    public let oldestFilename: String?
    public let staleCount: Int
    public let staleThreshold: Int
    public let longestStallDays: Int?
    public let longestStallFilename: String?
    public let longestStallStage: String?
}

public struct FlowSeries: Hashable {
    public let periods: [Day]
    public let arrivals: [Int]
    public let resolutions: [Int]
    public let cumulativeArrivals: [Int]
    public let cumulativeResolutions: [Int]
    public let backlog: [Int]
}

public enum FlowPeriod: String, CaseIterable, Identifiable {
    case weekly, monthly
    public var id: String { rawValue }
}

/// Ports of `metrics.py` and the backlog/throughput parts of `dashboard.py`.
public enum Analytics {
    public static let resolutionFields = ["ds_delegated", "ds_reference", "ds_archive"]
    static let fieldLabel = ["ds_triage": "triage", "ds_actionable": "actionable", "ds_delegated": "delegated",
                             "ds_reference": "reference", "ds_archive": "archive"]
    static let datePrefixRx = Rx("^([0-9]{4})-([0-9]{2})-([0-9]{2})")

    /// `email_date_from_filename`.
    public static func emailDate(fromFilename name: String) -> Day? {
        guard let m = datePrefixRx.firstMatch(name), let y = Int(m.group(1) ?? ""), let mo = Int(m.group(2) ?? ""),
              let d = Int(m.group(3) ?? "") else { return nil }
        return Day(validYear: y, month: mo, day: d)
    }

    /// `parse_ds`.
    public static func parseDS(_ value: String?) -> Day? {
        let v = (value ?? "").pyStrip
        guard !v.isEmpty else { return nil }
        return Day(iso: v)
    }

    static func resolutionDates(_ row: Metadata.Row) -> [Day] {
        resolutionFields.compactMap { parseDS(row[$0]) }
    }

    /// `resolution_of`: the latest resolution stamp.
    public static func resolution(_ row: Metadata.Row) -> Day? { resolutionDates(row).max() }

    /// `earliest_resolution_date`.
    public static func earliestResolution(_ row: Metadata.Row) -> Day? { resolutionDates(row).min() }

    // MARK: Autofix

    static func folderStampFixes(_ folder: Folder, _ row: Metadata.Row, today: Day) -> [(String, String)] {
        guard let field = folder.stampField, parseDS(row[field]) == nil else { return [] }
        return [(field, today.iso)]
    }

    static func dateBackfillFixes(_ row: Metadata.Row, today: Day, inTriage: Bool, inActionable: Bool) -> [(String, String)] {
        var fixes: [(String, String)] = []
        func put(_ field: String, _ value: String) {
            if let i = fixes.firstIndex(where: { $0.0 == field }) { fixes[i].1 = value } else { fixes.append((field, value)) }
        }
        var triage = parseDS(row["ds_triage"])
        let actionable = parseDS(row["ds_actionable"])
        let earliest = earliestResolution(row)
        if actionable != nil && triage == nil {
            put("ds_triage", (row["ds_actionable"] ?? "").pyStrip)
            triage = actionable
        }
        if let earliest {
            if triage == nil && actionable == nil {
                put("ds_triage", earliest.iso)
                put("ds_actionable", earliest.iso)
            } else if actionable == nil {
                put("ds_actionable", earliest.iso)
            }
        } else {
            if actionable == nil && inActionable {
                if triage == nil { put("ds_triage", today.iso) }
                put("ds_actionable", today.iso)
            } else if triage == nil && inTriage {
                put("ds_triage", today.iso)
            }
        }
        return fixes
    }

    /// `plan_autofix`.
    public static func planAutofix(_ records: [AutofixRecord], today: Day) -> ([AutofixFix], [AutofixBlocker]) {
        var fixes: [AutofixFix] = []
        var blockers: [AutofixBlocker] = []
        for rec in records {
            var row = rec.row
            for (field, new) in folderStampFixes(rec.folder, row, today: today) {
                fixes.append(AutofixFix(filename: rec.filename, folder: rec.folder, field: field,
                                        old: row[field] ?? "", new: new, phase: .folderConsistency))
                row[field] = new
            }
            let inTriage = rec.folder == .triage
            let inActionable = rec.folder == .actionable
            if earliestResolution(row) == nil && parseDS(row["ds_triage"]) == nil && !inTriage && !inActionable {
                blockers.append(AutofixBlocker(
                    filename: rec.filename, folder: rec.folder,
                    reason: "ongoing email in \(rec.folder.rawValue) with no ds_triage and no resolution stamp \u{2014} cannot infer its dates"))
                continue
            }
            for (field, new) in dateBackfillFixes(row, today: today, inTriage: inTriage, inActionable: inActionable) {
                fixes.append(AutofixFix(filename: rec.filename, folder: rec.folder, field: field,
                                        old: row[field] ?? "", new: new, phase: .dateBackfill))
            }
        }
        return (fixes, blockers)
    }

    // MARK: Metrics

    /// `compute_email_metrics`.
    public static func computeMetrics(filename: String, row: Metadata.Row) -> EmailMetrics {
        let e = emailDate(fromFilename: filename)
        let t = parseDS(row["ds_triage"])
        let a = parseDS(row["ds_actionable"])
        let r = resolution(row)
        let resStages: [EmailMetrics.Stage] = resolutionFields.compactMap { f in
            parseDS(row[f]).map { EmailMetrics.Stage(label: fieldLabel[f]!, day: $0) }
        }
        var chain: [Day] = e.map { [$0] } ?? []
        if let t { chain.append(t) }
        if let a { chain.append(a) }
        chain.append(contentsOf: resStages.map(\.day))
        var weird = e == nil
        if chain.count > 1 {
            for i in 0..<(chain.count - 1) where chain[i] > chain[i + 1] { weird = true }
        }
        let status: EmailMetrics.Status = weird ? .weird : (r != nil ? .resolved : .ongoing)
        guard !weird, let e else {
            return EmailMetrics(filename: filename, emailDate: e, triageDate: t, actionableDate: a, resolutionDate: r,
                                status: status, metrics: [:], stages: [])
        }
        var m: [String: Int] = [:]
        if let t { m["ttS"] = t.days(since: e) }
        if let t, let a { m["Td"] = a.days(since: t) }
        if let r, let a { m["Wd"] = r.days(since: a) }
        if let r { m["tttR"] = r.days(since: e) }
        var stages = [EmailMetrics.Stage(label: "took place", day: e)]
        if let t { stages.append(.init(label: "triage", day: t)) }
        if let a { stages.append(.init(label: "actionable", day: a)) }
        stages.append(contentsOf: resStages)
        return EmailMetrics(filename: filename, emailDate: e, triageDate: t, actionableDate: a, resolutionDate: r,
                            status: status, metrics: m, stages: stages)
    }

    // MARK: Backlog (dashboard.py)

    static func mean(_ values: [Int]) -> Double? {
        values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
    }

    static func median(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? Double(s[mid]) : Double(s[mid - 1] + s[mid]) / 2
    }

    /// `build_backlog_stats`.
    public static func backlogStats(_ computed: [EmailMetrics], today: Day) -> BacklogStats {
        let ongoing = computed.filter { $0.status == .ongoing && $0.emailDate != nil }
        let ages = ongoing.map { today.days(since: $0.emailDate!) }
        var oldestFilename: String?
        var stallDays: Int?
        var stallFilename: String?
        var stallStage: String?
        if !ongoing.isEmpty {
            // Python's max() keeps the first of equal maxima.
            var best = ongoing[0]
            for e in ongoing.dropFirst() where today.days(since: e.emailDate!) > today.days(since: best.emailDate!) {
                best = e
            }
            oldestFilename = best.filename
            func stall(_ e: EmailMetrics) -> (Int, String) {
                let latest = e.actionableDate ?? e.triageDate ?? e.emailDate!
                let stage = e.actionableDate != nil ? "actionable" : (e.triageDate != nil ? "triage" : "arrival")
                return (today.days(since: latest), stage)
            }
            var stalled = ongoing[0]
            for e in ongoing.dropFirst() where stall(e).0 > stall(stalled).0 { stalled = e }
            let (days, stage) = stall(stalled)
            stallDays = days
            stallFilename = stalled.filename
            stallStage = stage
        }
        return BacklogStats(count: ongoing.count, meanAge: mean(ages), medianAge: median(ages),
                            oldestAge: ages.max(), oldestFilename: oldestFilename,
                            staleCount: ages.filter { $0 > Rules.staleThresholdDays }.count,
                            staleThreshold: Rules.staleThresholdDays, longestStallDays: stallDays,
                            longestStallFilename: stallFilename, longestStallStage: stallStage)
    }

    public static let histogramLabels = ["0\u{2013}7", "8\u{2013}14", "15\u{2013}30", "31\u{2013}90", "90+"]

    /// `build_backlog_age_histogram`: counts per open-age band.
    public static func backlogHistogram(_ computed: [EmailMetrics], today: Day) -> [Int] {
        let bands: [(Int, Int?)] = [(0, 7), (8, 14), (15, 30), (31, 90), (91, nil)]
        var counts = [Int](repeating: 0, count: bands.count)
        for e in computed where e.status == .ongoing {
            guard let d = e.emailDate else { continue }
            let age = today.days(since: d)
            for (i, band) in bands.enumerated() where age >= band.0 && (band.1 == nil || age <= band.1!) {
                counts[i] += 1
                break
            }
        }
        return counts
    }

    /// `_period_key`: the Monday of the week, or the 1st of the month.
    public static func periodKey(_ d: Day, _ period: FlowPeriod) -> Day {
        switch period {
        case .weekly: return d.adding(days: -d.weekday)
        case .monthly: return Day(year: d.year, month: d.month, day: 1)
        }
    }

    /// `build_flow_series`: arrivals vs resolutions per period, gap-filled.
    public static func flowSeries(_ computed: [EmailMetrics], period: FlowPeriod) -> FlowSeries {
        var arrivals: [Day: Int] = [:]
        var resolutions: [Day: Int] = [:]
        for e in computed where e.status != .weird {
            if let d = e.emailDate { arrivals[periodKey(d, period), default: 0] += 1 }
            if e.status == .resolved, let r = e.resolutionDate { resolutions[periodKey(r, period), default: 0] += 1 }
        }
        let keys = Set(arrivals.keys).union(resolutions.keys)
        guard let start = keys.min(), let end = keys.max() else {
            return FlowSeries(periods: [], arrivals: [], resolutions: [], cumulativeArrivals: [],
                              cumulativeResolutions: [], backlog: [])
        }
        var periods: [Day] = []
        var cur = start
        while cur <= end {
            periods.append(cur)
            switch period {
            case .weekly: cur = cur.adding(days: 7)
            case .monthly: cur = cur.month == 12 ? Day(year: cur.year + 1, month: 1, day: 1)
                                                 : Day(year: cur.year, month: cur.month + 1, day: 1)
            }
        }
        let arr = periods.map { arrivals[$0] ?? 0 }
        let res = periods.map { resolutions[$0] ?? 0 }
        var cumA: [Int] = [], cumR: [Int] = [], backlog: [Int] = []
        var ra = 0, rr = 0
        for (a, r) in zip(arr, res) {
            ra += a
            rr += r
            cumA.append(ra)
            cumR.append(rr)
            backlog.append(ra - rr)
        }
        return FlowSeries(periods: periods, arrivals: arr, resolutions: res, cumulativeArrivals: cumA,
                          cumulativeResolutions: cumR, backlog: backlog)
    }
}
