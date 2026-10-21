import Foundation
import XCTest
@testable import GTDCore

final class CoreTests: XCTestCase {
    func testDayArithmetic() {
        let d = Day(iso: "2026-09-30")!
        XCTAssertEqual(d.weekday, 2)  // a Wednesday
        XCTAssertEqual(d.adding(days: 1).iso, "2026-10-01")
        XCTAssertEqual(Day(iso: "2024-02-29")!.adding(days: 366).iso, "2025-03-01")
        XCTAssertEqual(Day(ordinal: d.ordinal), d)
        XCTAssertNil(Day(iso: "2026-02-30"))
        XCTAssertNil(Day(iso: "2026-9-30"))
    }

    func testFolderResolving() {
        XCTAssertEqual(Folder(resolving: "Delegated"), .delegated)
        XCTAssertEqual(Folder(resolving: "04-delegated"), .delegated)
        XCTAssertNil(Folder(resolving: "nope"))
        XCTAssertNil(Folder.input.stampField)
        XCTAssertEqual(Folder.archive.stampField, "ds_archive")
    }

    func testWorkspaceConfig() throws {
        let yaml = """
        # comment
        max_filename_chars: 40
        green_max_days: 3
        my_own_accounts:
          - email_address: Me@Example.com
            display_name: Work
            colour: YELLOW
          - email_address: other@example.org
            colour: purple
        monitored_hashtags: ["#urgent", " #family ", "#URGENT"]
        unknown_key: ignored
        """
        let c = try WorkspaceConfig.parse(yaml)
        XCTAssertEqual(c.maxFilenameChars, 40)
        XCTAssertEqual(c.greenMaxDays, 3)
        XCTAssertEqual(c.yellowMaxDays, 14)
        XCTAssertEqual(c.myOwnAccounts.map(\.emailAddress), ["me@example.com", "other@example.org"])
        XCTAssertEqual(c.myOwnAccounts.map(\.colour), ["yellow", "cyan"])
        XCTAssertEqual(c.myOwnAccounts[1].displayName, "other@example.org")
        XCTAssertEqual(c.monitoredHashtags, ["#urgent", "#family"])
        XCTAssertEqual(try WorkspaceConfig.parse(""), WorkspaceConfig())
        XCTAssertThrowsError(try WorkspaceConfig.parse("- just\n- a list\n"))
    }

    func testCSVRoundTrip() {
        var rows: [String: Metadata.Row] = [:]
        var row = Metadata.blankRow()
        row["general_notes"] = "a, \"b\"\nc"
        rows["b.eml"] = row
        rows["a.eml"] = Metadata.blankRow()
        let text = Metadata.render(rows)
        XCTAssertTrue(text.hasPrefix("eml_filename,general_notes,project,"))
        XCTAssertTrue(text.contains("\r\na.eml,,"))
        XCTAssertEqual(Metadata.parse(text)["b.eml"]?["general_notes"], "a, \"b\"\nc")
    }

    func testMultipartNesting() {
        let raw = """
        From: a@example.com
        Subject: Nested
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/plain

        Inner plain
        --inner
        Content-Type: text/html

        <b>Inner html</b>
        --inner--
        --outer
        Content-Type: text/plain; name="a.txt"
        Content-Disposition: attachment

        attached
        --outer--
        """
        let entity = MIMEParser.parse(Array(raw.utf8))
        XCTAssertTrue(entity.isMultipart)
        XCTAssertEqual(EmailUtil.bodyText(entity, renderHTML: true), "Inner plain")
        XCTAssertEqual(EmailUtil.attachments(entity), ["a.txt"])
    }

    func testBase64Lenient() {
        XCTAssertEqual(TransferEncoding.decodeBase64(Array("YQ==YQ==".utf8)), Array("a".utf8))
        XCTAssertEqual(TransferEncoding.decodeBase64(Array("YWJj!ZGVm".utf8)), Array("abcdef".utf8))
        XCTAssertNil(TransferEncoding.decodeBase64(Array("YWJjZ".utf8)))
    }

    func testQuotedPrintable() {
        XCTAssertEqual(TransferEncoding.decodeQuotedPrintable(Array("a=3Db=\nc==d=".utf8)), Array("a=bc=d".utf8))
    }

    func testDateBuckets() {
        let today = Day(iso: "2026-09-30")!  // Wednesday
        func title(_ iso: String) -> String {
            DateBucket.title(for: Day(iso: iso)!, today: today) { ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul",
                                                                   "Aug", "Sep", "Oct", "Nov", "Dec"][$0 - 1] }
        }
        XCTAssertEqual(title("2026-09-30"), "Today")
        XCTAssertEqual(title("2026-09-29"), "Yesterday")
        XCTAssertEqual(title("2026-09-28"), "This Week")
        XCTAssertEqual(title("2026-09-21"), "Last Week")
        XCTAssertEqual(title("2026-09-02"), "Earlier This Month")
        XCTAssertEqual(title("2026-08-15"), "Last Month")
        XCTAssertEqual(title("2026-03-15"), "Mar")
        XCTAssertEqual(title("2025-12-31"), "2025")
    }

    func testHashtagKey() {
        XCTAssertEqual(Rules.hashtagKey("#urgent"), "tag-urgent")
        XCTAssertEqual(Rules.hashtagKey("#follow up!"), "tag-follow-up")
        XCTAssertEqual(Rules.hashtagKey("#urgent", taken: ["tag-urgent"]), "tag-urgent-2")
        XCTAssertEqual(Rules.hashtagKey("!!!"), "tag-tag")
    }

    func testImportAndLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gtd-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = Workspace(root: root)
        ws.today = { Day(iso: "2026-09-30")! }
        try ws.ensureFolders()
        let source = root.appendingPathComponent("drop.eml")
        try Data("From: x@example.com\nSubject: Dropped\nDate: Wed, 30 Sep 2026 09:00:00 +0000\n\nHi\n".utf8)
            .write(to: source)
        XCTAssertEqual(try ws.importToInput([source, source]), ["drop.eml", "drop-2.eml"])
        let before = RecordLoader().load(ws, config: WorkspaceConfig())
        XCTAssertEqual(before.records.count, 2)
        XCTAssertEqual(before.records.first?.status, "untracked")
        XCTAssertEqual(before.autofix.pendingInput, 2)
        XCTAssertEqual(Overview(before.records).attention.first?.count, 2)

        let moved = try ws.ingest(maxFilenameChars: 60)
        XCTAssertEqual(moved.map(\.newName), ["2026-09-30-dropped.eml", "2026-09-30-dropped-2.eml"])
        let after = RecordLoader().load(ws, config: WorkspaceConfig())
        XCTAssertTrue(after.autofix.isClean)
        XCTAssertEqual(after.records.map(\.status), ["ongoing", "ongoing"])
        XCTAssertEqual(after.records.first?.stamps.first?.date, "2026-09-30")

        // Refusals match the CLI wording.
        try ws.alloc("2026-09-30-dropped.eml", to: .actionable)
        XCTAssertThrowsError(try ws.alloc("2026-09-30-dropped.eml", to: .triage)) { error in
            XCTAssertTrue((error as? GTDError)?.message.contains("already has ds_triage = 2026-09-30") ?? false)
        }
        XCTAssertThrowsError(try ws.setFields("2026-09-30-dropped.eml", ["ds_triage": "x"]))
        let warnings = try ws.setFields("2026-09-30-dropped.eml", ["due_date": "soon"])
        XCTAssertEqual(warnings.count, 1)
    }

    func testCalendarIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gtd-cal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = Workspace(root: root)
        ws.today = { Day(iso: "2026-09-30")! }
        try ws.ensureFolders()
        let raw = """
        From: jane@example.com
        Subject: Re: Lunch
        Date: Mon, 28 Sep 2026 23:30:00 -0700

        Fine.

        On Fri, 25 Sep 2026 at 10:00, Me <me@example.com> wrote:
        > Lunch?
        """
        try Data(raw.utf8).write(to: ws.url(.input, "a.eml"))
        try ws.ingest(maxFilenameChars: 60)
        let name = try XCTUnwrap(ws.listEML(.triage).first)
        try ws.alloc(name, to: .archive)
        let snapshot = RecordLoader().load(ws, config: WorkspaceConfig())
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let index = CalendarIndex.build(snapshot.records, instantDay: { date in
            let c = utc.dateComponents([.year, .month, .day], from: date)
            return Day(year: c.year!, month: c.month!, day: c.day!)
        }, quotedDay: { Day(validYear: $0.y, month: $0.mo, day: $0.d) })
        let id = Folder.archive.rawValue + "/" + name
        // The Date header is 29 Sep in UTC; the quoted reply was on the 25th.
        XCTAssertEqual(index.kinds(on: Day(iso: "2026-09-29")!, for: id), [.received])
        XCTAssertEqual(index.kinds(on: Day(iso: "2026-09-25")!, for: id), [.quoted])
        XCTAssertEqual(index.kinds(on: Day(iso: "2026-09-30")!, for: id), [.triaged, .archived])
        XCTAssertEqual(index.count(on: Day(iso: "2026-09-30")!), 1)
        XCTAssertEqual(index.count(on: Day(iso: "2026-09-28")!), 0)
        XCTAssertEqual(CalendarIndex.shift(Day(iso: "2026-01-01")!, by: -1).iso, "2025-12-01")
        XCTAssertEqual(CalendarIndex.monthDays(Day(iso: "2028-02-01")!).count, 29)
    }

    func testCloseHistory() {
        func node(_ name: String, _ action: String = "", epoch: Int = 0, folder: Folder = .archive) -> CloseHistory.Node {
            CloseHistory.Node(id: folder.rawValue + "/" + name, filename: name, nextAction: action, epoch: epoch)
        }
        XCTAssertEqual(CloseHistory.closingReference("Closed with b.eml"), "b.eml")
        XCTAssertEqual(CloseHistory.closingReference("  closed with B.EML, see notes"), "B.EML")
        XCTAssertEqual(CloseHistory.closingReference("Closed with 2026-09-20-re-contract.eml."), "2026-09-20-re-contract.eml")
        XCTAssertNil(CloseHistory.closingReference("Closed with b.emlx"))
        XCTAssertNil(CloseHistory.closingReference("Closed with Bob on the phone"))
        XCTAssertNil(CloseHistory.closingReference("Check whether it was closed with b.eml"))

        // a -> c, b -> c, c -> d (open), plus an unrelated email.
        let history = CloseHistory(nodes: [
            node("b.eml", "Closed with c.eml", epoch: 20),
            node("a.eml", "Closed with c.eml", epoch: 10),
            node("c.eml", "Closed with D.eml", epoch: 30),
            node("d.eml", "Reply to Jane #urgent", epoch: 40, folder: .actionable),
            node("e.eml", "", epoch: 5, folder: .triage),
        ])
        let chain = history.chain(for: "03-actionable/d.eml")
        XCTAssertEqual(chain.map(\.filename), ["a.eml", "b.eml", "c.eml", "d.eml"])
        XCTAssertEqual(chain.map(\.closedBy), ["06-archive/c.eml", "06-archive/c.eml", "03-actionable/d.eml", nil])
        XCTAssertEqual(history.chain(for: "06-archive/a.eml"), chain)
        XCTAssertFalse(history.isInChain("02-triage/e.eml"))
        XCTAssertTrue(history.chain(for: "02-triage/e.eml").isEmpty)

        // A missing closer stays in the chain; a self-reference is no link;
        // a loop still lists every email once.
        let odd = CloseHistory(nodes: [
            node("x.eml", "Closed with gone.eml"),
            node("y.eml", "Closed with y.eml"),
            node("p.eml", "Closed with q.eml", epoch: 2),
            node("q.eml", "Closed with p.eml", epoch: 1),
        ])
        let missing = odd.chain(for: "06-archive/x.eml")
        XCTAssertEqual(missing.map(\.filename), ["x.eml", "gone.eml"])
        XCTAssertEqual(missing.map(\.isMissing), [false, true])
        XCTAssertNil(missing.last?.recordID)
        XCTAssertFalse(odd.isInChain("06-archive/y.eml"))
        XCTAssertEqual(odd.chain(for: "06-archive/p.eml").map(\.filename), ["q.eml", "p.eml"])
    }

    func testSetNextActionIfBlank() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gtd-tag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = Workspace(root: root)
        ws.today = { Day(iso: "2026-09-30")! }
        try ws.ensureFolders()
        for subject in ["One", "Two"] {
            try Data("From: x@example.com\nSubject: \(subject)\nDate: Wed, 30 Sep 2026 09:00:00 +0000\n\nHi\n".utf8)
                .write(to: ws.url(.input, "\(subject).eml"))
        }
        try ws.ingest(maxFilenameChars: 60)
        try ws.setFields("2026-09-30-one.eml", ["next_action": "  "])
        try ws.setFields("2026-09-30-two.eml", ["next_action": "Call Bob"])

        XCTAssertNil(ws.nextActionRefusal("2026-09-30-one.eml"))
        try ws.setNextActionIfBlank("2026-09-30-one.eml", "#urgent")
        XCTAssertEqual(ws.loadMetadata()["2026-09-30-one.eml"]?["next_action"], "#urgent")

        XCTAssertThrowsError(try ws.setNextActionIfBlank("2026-09-30-two.eml", "#urgent")) { error in
            XCTAssertTrue((error as? GTDError)?.message.contains("already has a next action (Call Bob)") ?? false)
        }
        XCTAssertEqual(ws.loadMetadata()["2026-09-30-two.eml"]?["next_action"], "Call Bob")
        XCTAssertThrowsError(try ws.setNextActionIfBlank("nope.eml", "#urgent"))
    }
}
