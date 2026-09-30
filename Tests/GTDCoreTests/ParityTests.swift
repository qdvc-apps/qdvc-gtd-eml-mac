import Foundation
import XCTest
@testable import GTDCore

/// Checks GTDCore against reference outputs recorded in `Fixtures/parity.json`,
/// which `tools/make_fixtures.py` produces by running the Python edition
/// (qdvc-gtd-eml). The fixture is committed, so these tests need nothing else.
final class ParityTests: XCTestCase {
    typealias JSON = [String: Any]

    private static let fixtures: JSON = {
        guard let url = Bundle.module.url(forResource: "parity", withExtension: "json", subdirectory: "Fixtures") else {
            fatalError("parity.json missing from test bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? JSON else {
                fatalError("parity.json is not an object")
            }
            return json
        } catch {
            fatalError("Could not read parity.json: \(error)")
        }
    }()

    private var fx: JSON { Self.fixtures }
    private func list(_ key: String) -> [JSON] { fx[key] as? [JSON] ?? [] }
    private var today: Day { Day(iso: fx["today"] as! String)! }
    private var nowUTC: Date { Date(timeIntervalSince1970: TimeInterval(fx["now_utc"] as! Int)) }
    private var accounts: [OwnAccount] { WorkspaceConfig.normaliseAccounts(fx["accounts_raw"] as Any) }

    private func string(_ v: Any?) -> String? { v as? String }
    private func strings(_ v: Any?) -> [String] { v as? [String] ?? [] }

    // MARK: - Configuration

    func testNormaliseAccounts() {
        for c in list("normalise_accounts") {
            let got = WorkspaceConfig.normaliseAccounts(c["input"] as Any)
            let want = c["output"] as? [JSON] ?? []
            XCTAssertEqual(got.count, want.count)
            for (g, w) in zip(got, want) {
                XCTAssertEqual(g.emailAddress, w["email_address"] as? String)
                XCTAssertEqual(g.displayName, w["display_name"] as? String)
                XCTAssertEqual(g.colour, w["colour"] as? String)
            }
        }
    }

    func testNormaliseHashtags() {
        for c in list("normalise_hashtags") {
            XCTAssertEqual(WorkspaceConfig.normaliseHashtags(c["input"] as Any), strings(c["output"]))
        }
    }

    // MARK: - Headers, dates, names

    func testDecodeMime() {
        for c in list("decode_mime") {
            let input = c["input"] as! String
            XCTAssertEqual(HeaderDecoding.decodeMime(HeaderValue(text: input, eightBit: false)),
                           c["output"] as? String, input.debugDescription)
        }
    }

    func testParseDate() {
        for c in list("parse_date") {
            let input = c["input"] as! String
            let got = DateParsing.parse(input)
            guard let want = c["output"] as? JSON else {
                XCTAssertNil(got, input)
                continue
            }
            guard let got else {
                XCTFail("no date for \(input)")
                continue
            }
            XCTAssertEqual(got.epoch, want["epoch"] as? Int, input)
            XCTAssertEqual(got.offset, want["offset"] as? Int, input)
            XCTAssertEqual(got.day.iso, want["day"] as? String, input)
            XCTAssertEqual(got.minuteString, want["minute"] as? String, input)
        }
    }

    func testSlugify() {
        for c in list("slugify") {
            XCTAssertEqual(Naming.slugify(c["input"] as! String), c["output"] as? String)
        }
    }

    func testBuildBaseFilename() {
        for c in list("build_base_filename") {
            let got = Naming.buildBaseFilename(day: Day(iso: c["date"] as! String)!, subject: c["subject"] as! String,
                                               maxChars: c["max_chars"] as! Int, messageRef: c["ref"] as? String)
            XCTAssertEqual(got, c["output"] as? String, "\(c)")
        }
    }

    func testUniqueFilename() {
        for c in list("unique_filename") {
            let got = Naming.uniqueFilename(base: c["base"] as! String, existing: Set(strings(c["existing"])),
                                            maxChars: c["max_chars"] as! Int, messageRef: c["ref"] as? String)
            XCTAssertEqual(got, c["output"] as? String, "\(c)")
        }
    }

    func testStripHTML() {
        for c in list("strip_html") {
            XCTAssertEqual(EmailUtil.stripHTML(c["input"] as! String), c["output"] as? String)
        }
    }

    func testParseFlagsAndColours() {
        for c in list("parse_flags") {
            XCTAssertEqual(Rules.parseFlags(c["input"] as! String).sorted(by: codePointPrecedes), strings(c["output"]))
        }
        for c in list("colour_for_days") {
            XCTAssertEqual(Rules.ageClass(days: c["days"] as! Int, greenMax: 2, yellowMax: 14).rawValue,
                           c["output"] as? String)
        }
    }

    // MARK: - Threads

    private func assertParts(_ got: DateParts?, _ want: Any?, _ label: String, file: StaticString = #filePath,
                             line: UInt = #line) {
        guard let w = want as? JSON else {
            XCTAssertNil(got, label, file: file, line: line)
            return
        }
        guard let got else {
            XCTFail("no date parts for \(label)", file: file, line: line)
            return
        }
        XCTAssertEqual(got.y, w["y"] as? Int, label, file: file, line: line)
        XCTAssertEqual(got.mo, w["mo"] as? Int, label, file: file, line: line)
        XCTAssertEqual(got.d, w["d"] as? Int, label, file: file, line: line)
        XCTAssertEqual(got.h, w["h"] as? Int, label, file: file, line: line)
        XCTAssertEqual(got.mi, w["mi"] as? Int, label, file: file, line: line)
        XCTAssertEqual(got.s, w["s"] as? Int, label, file: file, line: line)
        XCTAssertEqual(got.offset, w["offset"] as? Int, label, file: file, line: line)
    }

    private func assertThread(_ got: [ThreadMessage], _ want: [JSON], _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "message count for \(label)", file: file, line: line)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.depth, w["depth"] as? Int, label, file: file, line: line)
            XCTAssertEqual(g.text, w["text"] as? String, label, file: file, line: line)
            XCTAssertEqual(g.from, w["from"] as? String, label, file: file, line: line)
            XCTAssertEqual(g.date, w["date"] as? String, label, file: file, line: line)
            XCTAssertEqual(g.to, w["to"] as? String, label, file: file, line: line)
            XCTAssertEqual(g.cc, w["cc"] as? String, label, file: file, line: line)
            XCTAssertEqual(g.subject, w["subject"] as? String, label, file: file, line: line)
            XCTAssertEqual(g.replyTo, w["reply_to"] as? String, label, file: file, line: line)
            assertParts(g.dateParts, w["dateParts"], label, file: file, line: line)
        }
    }

    func testSplitHistory() {
        for c in list("split_history") {
            let input = c["input"] as! String
            assertThread(EmailThread.splitHistory(input), c["output"] as? [JSON] ?? [], input.debugDescription)
            XCTAssertEqual(EmailThread.summarise(input), c["summary"] as? String, input.debugDescription)
        }
    }

    func testParseDateText() {
        for c in list("parse_date_text") {
            let input = c["input"] as! String
            assertParts(EmailThread.parseDateText(input), c["output"], input)
        }
    }

    // MARK: - Whole emails

    func testEmails() {
        let todayUTC = Day.today(in: TimeZone(identifier: "UTC")!, now: nowUTC)
        for c in list("emails") {
            let name = c["name"] as! String
            let raw = Data(base64Encoded: c["raw_base64"] as! String)!
            let entity = MIMEParser.parse(raw)
            let p = ParsedEmail(message: entity)
            XCTAssertEqual(p.subject, c["subject"] as? String, name)
            XCTAssertEqual(p.messageRef, c["message_ref"] as? String, name)
            XCTAssertEqual(EmailUtil.bodyText(entity, renderHTML: false), c["body_raw"] as? String, name)
            XCTAssertEqual(p.body, c["body"] as? String, name)
            XCTAssertEqual(p.attachments, strings(c["attachments"]), name)
            XCTAssertEqual(p.fromText, c["from"] as? String, name)
            XCTAssertEqual(p.toText, c["to"] as? String, name)
            XCTAssertEqual(p.ccText, c["cc"] as? String, name)
            XCTAssertEqual(p.correspondents(excluding: accounts), strings(c["correspondents"]), name)
            XCTAssertEqual(p.ownAccount(accounts)?.displayName, c["own_account"] as? String, name)
            let roles = p.ownAccountsByRole(accounts)
            XCTAssertEqual(roles.recipient.map(\.displayName), strings(c["inbox"]), name)
            XCTAssertEqual(roles.sender.map(\.displayName), strings(c["sent"]), name)
            XCTAssertEqual(p.preview, c["preview"] as? String, name)
            assertThread(p.thread, c["thread"] as? [JSON] ?? [], name)
            if let want = c["date"] as? JSON {
                guard let d = p.date else {
                    XCTFail("no date for \(name)")
                    continue
                }
                XCTAssertEqual(d.epoch, want["epoch"] as? Int, name)
                XCTAssertEqual(d.offset, want["offset"] as? Int, name)
                XCTAssertEqual(d.day.iso, want["day"] as? String, name)
                XCTAssertEqual(Naming.buildBaseFilename(day: d.day, subject: p.subject, maxChars: 60,
                                                        messageRef: p.messageRef),
                               c["base_filename_60"] as? String, name)
                XCTAssertEqual(Naming.buildBaseFilename(day: d.day, subject: p.subject, maxChars: 40,
                                                        messageRef: p.messageRef),
                               c["base_filename_40"] as? String, name)
                XCTAssertEqual(todayUTC.days(since: d.day), c["age_days"] as? Int, name)
            } else {
                XCTAssertNil(p.date, name)
            }
        }
    }

    // MARK: - Analytics

    private func row(_ v: Any?) -> Metadata.Row { v as? [String: String] ?? [:] }

    func testPlanAutofix() {
        let section = fx["plan_autofix"] as! JSON
        let records = (section["records"] as! [JSON]).map {
            AutofixRecord(filename: $0["filename"] as! String, folder: Folder(rawValue: $0["folder"] as! String)!,
                          row: row($0["row"]))
        }
        let (fixes, blockers) = Analytics.planAutofix(records, today: today)
        let wantFixes = section["fixes"] as! [JSON]
        XCTAssertEqual(fixes.count, wantFixes.count)
        for (g, w) in zip(fixes, wantFixes) {
            XCTAssertEqual(g.filename, w["filename"] as? String)
            XCTAssertEqual(g.folder.rawValue, w["folder"] as? String)
            XCTAssertEqual(g.field, w["field"] as? String, g.filename)
            XCTAssertEqual(g.old, w["old"] as? String, g.filename)
            XCTAssertEqual(g.new, w["new"] as? String, g.filename)
            XCTAssertEqual(g.phase.rawValue, w["phase"] as? String, g.filename)
        }
        let wantBlockers = section["blockers"] as! [JSON]
        XCTAssertEqual(blockers.map(\.filename), wantBlockers.map { $0["filename"] as! String })
        XCTAssertEqual(blockers.map(\.reason), wantBlockers.map { $0["reason"] as! String })
    }

    private func computed() -> [EmailMetrics] {
        list("metrics").map { Analytics.computeMetrics(filename: $0["filename"] as! String, row: row($0["row"])) }
    }

    func testMetrics() {
        for (g, w) in zip(computed(), list("metrics")) {
            let f = g.filename
            XCTAssertEqual(g.status.rawValue, w["status"] as? String, f)
            XCTAssertEqual(g.metrics, w["metrics"] as? [String: Int] ?? [:], f)
            XCTAssertEqual(g.emailDate?.iso, w["email_date"] as? String, f)
            XCTAssertEqual(g.triageDate?.iso, w["triage_date"] as? String, f)
            XCTAssertEqual(g.actionableDate?.iso, w["actionable_date"] as? String, f)
            XCTAssertEqual(g.resolutionDate?.iso, w["resolution_date"] as? String, f)
            let stages = (w["stages"] as? [[Any]] ?? []).map { "\($0[0]) \($0[1])" }
            XCTAssertEqual(g.stages.map { "\($0.label) \($0.day.iso)" }, stages, f)
        }
    }

    func testBacklog() {
        let section = fx["backlog"] as! JSON
        let c = computed()
        let stats = Analytics.backlogStats(c, today: today)
        let want = section["stats"] as! JSON
        XCTAssertEqual(stats.count, want["count"] as? Int)
        XCTAssertEqual(stats.meanAge, want["mean_age"] as? Double)
        XCTAssertEqual(stats.medianAge, want["median_age"] as? Double)
        XCTAssertEqual(stats.oldestAge, want["oldest_age"] as? Int)
        XCTAssertEqual(stats.oldestFilename, want["oldest_filename"] as? String)
        XCTAssertEqual(stats.staleCount, want["stale_count"] as? Int)
        XCTAssertEqual(stats.longestStallDays, want["longest_stall_days"] as? Int)
        XCTAssertEqual(stats.longestStallFilename, want["longest_stall_filename"] as? String)
        XCTAssertEqual(stats.longestStallStage, want["longest_stall_stage"] as? String)

        let histogram = section["histogram"] as! JSON
        XCTAssertEqual(Analytics.histogramLabels, strings(histogram["labels"]))
        XCTAssertEqual(Analytics.backlogHistogram(c, today: today), histogram["counts"] as? [Int])

        for period in FlowPeriod.allCases {
            let w = section[period.rawValue] as! JSON
            let s = Analytics.flowSeries(c, period: period)
            XCTAssertEqual(s.periods.map(\.iso), strings(w["periods"]), period.rawValue)
            XCTAssertEqual(s.arrivals, w["arrivals"] as? [Int], period.rawValue)
            XCTAssertEqual(s.resolutions, w["resolutions"] as? [Int], period.rawValue)
            XCTAssertEqual(s.cumulativeArrivals, w["cumulative_arrivals"] as? [Int], period.rawValue)
            XCTAssertEqual(s.cumulativeResolutions, w["cumulative_resolutions"] as? [Int], period.rawValue)
            XCTAssertEqual(s.backlog, w["backlog"] as? [Int], period.rawValue)
        }
    }

    // MARK: - Workspace scenario (the CLI commands, replayed)

    private func state(_ ws: Workspace) -> (files: [String], csv: String?) {
        var files: [String] = []
        for folder in Folder.allCases {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: ws.folderURL(folder).path)) ?? []
            files += names.sorted(by: codePointPrecedes).map { "\(folder.rawValue)/\($0)" }
        }
        let csv = (try? Data(contentsOf: ws.metadataURL)).map { String(decoding: $0, as: UTF8.self) }
        return (files, csv)
    }

    func testScenario() throws {
        let steps = fx["scenario"] as! [JSON]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gtd-scenario-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = Workspace(root: root)
        let fixedToday = today
        ws.today = { fixedToday }
        try ws.ensureFolders()

        let initial = steps[0]
        for (path, b64) in initial["contents"] as! [String: String] {
            try Data(base64Encoded: b64)!.write(to: root.appendingPathComponent(path))
        }
        let initialState = initial["state"] as! JSON
        try Data((initialState["metadata_csv"] as! String).utf8).write(to: ws.metadataURL)

        for step in steps.dropFirst() {
            let op = step["op"] as! String
            let argv = strings(step["argv"])
            let label = "\(op) \(argv)"
            var code = 0
            do {
                switch op {
                case "ingest":
                    let moved = try ws.ingest(maxFilenameChars: 60)
                    let want = (step["moved"] as? [[String]]) ?? []
                    XCTAssertEqual(moved.map { [$0.oldName, $0.newName, $0.messageRef] }, want, label)
                case "alloc":
                    try ws.alloc(argv[0], to: Folder(resolving: argv[1])!)
                case "metadata":
                    var words = Array(argv.dropFirst(3))
                    if words.first == "=" { words.removeFirst() }
                    try ws.setFields(argv[0], [argv[2]: words.joined(separator: " ")])
                case "pin":
                    try ws.setFlag(argv[0], "pinned", on: true)
                case "unpin":
                    try ws.setFlag(argv[0], "pinned", on: false)
                case "close":
                    try ws.close(argv[0], with: argv.count == 3 ? argv[2] : argv[1])
                case "metadata_check":
                    let report = try ws.metadataCheck()
                    code = report.isClean ? 0 : 1
                case "autofix":
                    let plan = ws.planAutofix()
                    XCTAssertEqual(plan.fixes.count, (step["fixes"] as? [Any])?.count, label)
                    XCTAssertEqual(plan.blockers.count, (step["blockers"] as? [Any])?.count, label)
                    try ws.applyAutofix(plan)
                default:
                    XCTFail("unknown op \(op)")
                }
            } catch {
                code = 1
            }
            if let want = step["code"] as? Int { XCTAssertEqual(code, want, label) }
            let want = step["state"] as! JSON
            let got = state(ws)
            XCTAssertEqual(got.files, strings(want["files"]), label)
            XCTAssertEqual(got.csv, want["metadata_csv"] as? String, label)
        }
    }
}
