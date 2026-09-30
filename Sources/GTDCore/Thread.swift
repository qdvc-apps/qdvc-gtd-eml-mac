import Foundation

/// Date/time components recovered from a quoted header's date text
/// (`thread.parse_date_text`). `offset` (minutes east of UTC) is present only
/// when the text stated one.
public struct DateParts: Hashable, Codable {
    public var y: Int
    public var mo: Int
    public var d: Int
    public var h: Int?
    public var mi: Int?
    public var s: Int?
    public var offset: Int?
}

/// One message of a thread, newest first (depth 0 is the email itself).
public struct ThreadMessage: Hashable {
    public var depth: Int
    public var from: String?
    public var date: String?
    public var to: String?
    public var cc: String?
    public var bcc: String?
    public var subject: String?
    public var replyTo: String?
    public var dateParts: DateParts?
    public var text: String

    /// Nesting depth capped at 4, as the web UI indents.
    public var indent: Int { min(depth, 4) }

    public var hasHeaders: Bool {
        from != nil || date != nil || to != nil || cc != nil || subject != nil || replyTo != nil
    }
}

/// A port of `gtd_modules/thread.py`. A best-effort heuristic: `>` quote
/// depth plus the boundary markers mail clients actually emit.
public enum EmailThread {
    static let ruleMarker = Rx("^\\s*-{2,}\\s*(original message|forwarded message|original message follows|"
                               + "weitergeleitete nachricht|message d'origine)\\s*-{2,}\\s*$", [.caseInsensitive])
    static let forwardIntro = Rx("^\\s*(begin forwarded message|forwarded message)\\s*:?\\s*$", [.caseInsensitive])
    static let underscoreRule = Rx("^\\s*_{10,}\\s*$")
    static let headerLine = Rx("^\\s*(from|sent|date|to|cc|bcc|subject|reply-to)\\s*:\\s*(.*)$", [.caseInsensitive])
    static let attribution = Rx("^\\s*\\S.{0,300}?\\b(wrote|schrieb|a\\s+écrit|escribió)\\s*:\\s*$", [.caseInsensitive])
    static let attributionOpener = Rx("^\\s*(on|am|le|el)\\b", [.caseInsensitive])
    static let attributionTail = Rx("\\b(wrote|schrieb|a\\s+écrit|escribió)\\s*:\\s*$", [.caseInsensitive])
    static let attributionHead = Rx("^(on|am|le|el)\\b\\s*", [.caseInsensitive])
    static let attributionMaxLines = 3
    static let headerLookahead = 5
    static let headerKeyMap = ["from": "from", "sent": "date", "date": "date", "to": "to", "cc": "cc",
                               "bcc": "bcc", "subject": "subject", "reply-to": "reply_to"]

    /// `strip_quote_markers`: (depth, text without the markers).
    static func stripQuoteMarkers(_ line: String) -> (Int, String) {
        let s = Array(line.unicodeScalars)
        var depth = 0
        var i = 0
        while i < s.count {
            var j = i
            while j < s.count && (s[j] == " " || s[j] == "\t") { j += 1 }
            if j < s.count && s[j] == ">" {
                depth += 1
                i = j + 1
                if i < s.count && s[i] == " " { i += 1 }
            } else {
                break
            }
        }
        return depth > 0 ? (depth, String(String.UnicodeScalarView(s[i...]))) : (0, line)
    }

    typealias Headers = [(key: String, value: String)]

    static func set(_ headers: inout Headers, _ key: String, _ value: String) {
        if let i = headers.firstIndex(where: { $0.key == key }) {
            headers[i].value = (headers[i].value + " " + value).pyStrip
        } else {
            headers.append((key: key, value: value))
        }
    }

    /// `_parse_header_block`.
    static func parseHeaderBlock(_ lines: [String], _ start: Int) -> (Headers, Int) {
        var i = start
        while i < lines.count && lines[i].pyStrip.isEmpty { i += 1 }
        var headers: Headers = []
        var lastKey: String?
        while i < lines.count {
            let line = lines[i]
            if line.pyStrip.isEmpty {
                if !headers.isEmpty { i += 1 }
                break
            }
            if let m = headerLine.firstMatch(line) {
                let key = headerKeyMap[(m.group(1) ?? "").lowercased()]
                let value = (m.group(2) ?? "").pyStrip
                if let key {
                    set(&headers, key, value)
                    lastKey = key
                }
                i += 1
                continue
            }
            if !headers.isEmpty, let lastKey, let first = line.unicodeScalars.first, first == " " || first == "\t" {
                set(&headers, lastKey, line.pyStrip)
                i += 1
                continue
            }
            break
        }
        return (headers, headers.isEmpty ? start : i)
    }

    /// `_split_attribution`.
    static func splitAttribution(_ text: String) -> Headers {
        var body = attributionTail.replace(text.pyStrip, with: "").pyStrip.pyRStrip([","])
        body = attributionHead.replace(body, with: "").pyStrip
        guard !body.isEmpty else { return [] }
        if let comma = body.unicodeScalars.lastIndex(of: ",") {
            let left = String(body.unicodeScalars[..<comma]).pyStrip
            let right = String(body.unicodeScalars[body.unicodeScalars.index(after: comma)...]).pyStrip
            if right.contains("<") || right.contains("@") || left.isEmpty {
                let pairs: Headers = [(key: "date", value: left), (key: "from", value: right)]
                return pairs.filter { !$0.value.isEmpty }
            }
            if left.contains("<") || left.contains("@") {
                let pairs: Headers = [(key: "from", value: left), (key: "date", value: right)]
                return pairs.filter { !$0.value.isEmpty }
            }
        }
        return [(key: "from", value: body)]
    }

    /// `_marker_at`: (headers, lines consumed) or nil for ordinary text.
    static func marker(_ lines: [String], _ index: Int) -> (Headers, Int)? {
        let line = lines[index]
        if ruleMarker.matches(line) || forwardIntro.matches(line) {
            let (headers, after) = parseHeaderBlock(lines, index + 1)
            return (headers, max(after - index, 1))
        }
        if underscoreRule.matches(line) {
            let (headers, after) = parseHeaderBlock(lines, index + 1)
            return headers.isEmpty ? nil : (headers, after - index)
        }
        if let m = headerLine.firstMatch(line), (m.group(1) ?? "").lowercased() == "from" {
            let window = lines[min(index + 1, lines.count)..<min(index + 1 + headerLookahead, lines.count)]
            let confirmed = window.contains { w in
                guard let wm = headerLine.firstMatch(w) else { return false }
                let key = (wm.group(1) ?? "").lowercased()
                return key == "sent" || key == "date"
            }
            if confirmed {
                let (headers, after) = parseHeaderBlock(lines, index)
                if !headers.isEmpty { return (headers, after - index) }
            }
            return nil
        }
        if attribution.matches(line) { return (splitAttribution(line), 1) }
        if attributionOpener.matches(line) {
            var joined = line.pyRStrip(Set(" \t\n\r\u{0B}\u{0C}".unicodeScalars))
            for extra in 1..<attributionMaxLines {
                if index + extra >= lines.count { break }
                let next = lines[index + extra]
                if next.pyStrip.isEmpty { break }
                joined = joined + " " + next.pyStrip
                if attribution.matches(joined) { return (splitAttribution(joined), extra + 1) }
            }
        }
        return nil
    }

    // MARK: Quoted-header dates

    static let months: [String: Int] = {
        let names: [[String]] = [["january", "jan"], ["february", "feb"], ["march", "mar"], ["april", "apr"],
                                 ["may"], ["june", "jun"], ["july", "jul"], ["august", "aug"],
                                 ["september", "sep", "sept"], ["october", "oct"], ["november", "nov"],
                                 ["december", "dec"]]
        var map: [String: Int] = [:]
        for (i, group) in names.enumerated() { for n in group { map[n] = i + 1 } }
        return map
    }()
    static let monthAlternation = months.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        .joined(separator: "|")
    static let dmyRx = Rx("\\b([0-9]{1,2})\\s+(" + monthAlternation + ")\\.?,?\\s+([0-9]{4})\\b", [.caseInsensitive])
    static let mdyRx = Rx("\\b(" + monthAlternation + ")\\.?\\s+([0-9]{1,2})(?:st|nd|rd|th)?,?\\s+([0-9]{4})\\b",
                          [.caseInsensitive])
    static let isoRx = Rx("\\b([0-9]{4})-([0-9]{2})-([0-9]{2})\\b")
    static let timeRx = Rx("\\b([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?\\s*([ap])\\.?m\\.?\\b|\\b([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?\\b",
                           [.caseInsensitive])
    static let offsetRx = Rx("(?:GMT|UTC)?\\s*([+-])([0-9]{2}):?([0-9]{2})\\b|\\b(UTC|GMT|Z)\\b", [.caseInsensitive])

    /// `parse_date_text`.
    public static func parseDateText(_ raw: String?) -> DateParts? {
        guard let raw, !raw.isEmpty else { return nil }
        let text = raw.pyStrip
        var parts: DateParts?
        if let m = isoRx.firstMatch(text) {
            parts = DateParts(y: Int(m.group(1)!)!, mo: Int(m.group(2)!)!, d: Int(m.group(3)!)!)
        }
        if parts == nil, let m = dmyRx.firstMatch(text), let mo = months[m.group(2)!.lowercased()] {
            parts = DateParts(y: Int(m.group(3)!)!, mo: mo, d: Int(m.group(1)!)!)
        }
        if parts == nil, let m = mdyRx.firstMatch(text), let mo = months[m.group(1)!.lowercased()] {
            parts = DateParts(y: Int(m.group(3)!)!, mo: mo, d: Int(m.group(2)!)!)
        }
        guard var p = parts, (1...12).contains(p.mo), (1...31).contains(p.d) else { return nil }
        if let t = timeRx.firstMatch(text) {
            var hour: Int
            var minute: Int
            var second: String?
            if let h12 = t.group(1) {
                hour = Int(h12)! % 12
                if (t.group(4) ?? "").lowercased() == "p" { hour += 12 }
                minute = Int(t.group(2)!)!
                second = t.group(3)
            } else {
                hour = Int(t.group(5)!)!
                minute = Int(t.group(6)!)!
                second = t.group(7)
            }
            if (0...23).contains(hour) && (0...59).contains(minute) {
                p.h = hour
                p.mi = minute
                if let second, let sv = Int(second), (0...59).contains(sv) { p.s = sv }
            }
        }
        if let o = offsetRx.firstMatch(text) {
            if let sign = o.group(1) {
                let value = Int(o.group(2)!)! * 60 + Int(o.group(3)!)!
                p.offset = sign == "+" ? value : -value
            } else {
                p.offset = 0
            }
        }
        return p
    }

    static let blankRunRx = Rx("\\n{3,}")

    /// `_tidy`.
    static func tidy(_ lines: [String]) -> String {
        blankRunRx.replace(lines.joined(separator: "\n"), with: "\n\n").pyStrip(["\n"])
    }

    /// `split_history`: the messages in a body, newest first.
    public static func splitHistory(_ bodyText: String) -> [ThreadMessage] {
        guard !bodyText.pyStrip.isEmpty else { return [] }
        let rawLines = bodyText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").pySplit("\n")
        var depths: [Int] = []
        var texts: [String] = []
        for line in rawLines {
            let (depth, text) = stripQuoteMarkers(line)
            depths.append(depth)
            texts.append(text)
        }

        final class Building {
            var depth: Int
            var qdepth: Int?
            var lines: [String]
            var headers: Headers = []
            init(depth: Int, qdepth: Int?, lines: [String]) {
                self.depth = depth
                self.qdepth = qdepth
                self.lines = lines
            }
        }
        var messages = [Building(depth: 0, qdepth: nil, lines: [])]
        var current = messages[0]
        var i = 0
        while i < texts.count {
            if let found = marker(texts, i) {
                let (headers, consumed) = found
                current = Building(depth: max(current.depth + 1, depths[i]), qdepth: nil, lines: [])
                current.headers = headers
                messages.append(current)
                i += consumed
                continue
            }
            let line = texts[i]
            let depth = depths[i]
            if line.pyStrip.isEmpty {
                current.lines.append(line)
                i += 1
                continue
            }
            let here = current.qdepth ?? depth
            if depth > here {
                current = Building(depth: max(current.depth + 1, depth), qdepth: depth, lines: [line])
                messages.append(current)
                i += 1
                continue
            }
            if depth < here, let resumed = messages.last(where: { $0.qdepth == depth }) {
                current = resumed
            }
            if current.qdepth == nil { current.qdepth = depth }
            current.lines.append(line)
            i += 1
        }

        var result: [ThreadMessage] = []
        for m in messages {
            func header(_ key: String) -> String? { m.headers.first { $0.key == key }?.value }
            let text = tidy(m.lines)
            let message = ThreadMessage(depth: m.depth, from: header("from"), date: header("date"),
                                        to: header("to"), cc: header("cc"), bcc: header("bcc"),
                                        subject: header("subject"), replyTo: header("reply_to"),
                                        dateParts: header("date").flatMap { $0.isEmpty ? nil : parseDateText($0) },
                                        text: text)
            // (Python's check leaves Bcc out, so a Bcc-only shell is dropped.)
            let hasHeaders = m.headers.contains { $0.key != "bcc" }
            if text.isEmpty && !hasHeaders { continue }
            result.append(message)
        }
        return result
    }

    static let whitespaceRunRx = Rx("\\s+")

    /// `summarise`: a one-line preview of the newest message.
    public static func summarise(_ bodyText: String, maxChars: Int = 140) -> String {
        var text = ""
        for m in splitHistory(bodyText) where !m.text.pyStrip.isEmpty {
            text = m.text
            break
        }
        text = whitespaceRunRx.replace(text, with: " ").pyStrip
        if maxChars > 0 && text.pyCount > maxChars {
            return text.pyPrefix(maxChars - 1).pyRStrip(Set(" \t\n\r\u{0B}\u{0C}".unicodeScalars)) + "\u{2026}"
        }
        return text
    }
}
