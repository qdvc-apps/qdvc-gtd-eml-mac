import Foundation

// MARK: - Addresses (email.utils.getaddresses, strict mode)

/// A parsed address: `(realname, email)` as Python returns it.
public struct AddressPair: Hashable {
    public let name: String
    public let address: String
}

public enum Addresses {
    /// `email.utils.getaddresses(fieldvalues)` with the default `strict=True`.
    public static func getaddresses(_ values: [String]) -> [AddressPair] {
        let checked = values.map { checkParenthesis($0) ? $0 : "('', '')" }
        let joined = checked.joined(separator: ", ")
        let parsed = joined.isEmpty ? [] : AddrlistParser(joined).getaddrlist()
        let result = parsed.map { pair in pair.address.contains("[") ? AddressPair(name: "", address: "") : pair }
        var expected = 0
        for v in checked {
            expected += 1 + stripQuotedRealnames(v).unicodeScalars.filter { $0 == "," }.count
        }
        if result.count != expected { return [AddressPair(name: "", address: "")] }
        return result
    }

    /// `(position, character-or-escape)` pairs, as `_iter_escaped_chars`.
    static func escapedChars(_ s: [Unicode.Scalar]) -> [(Int, String)] {
        var out: [(Int, String)] = []
        var escape = false
        var pos = 0
        for (i, c) in s.enumerated() {
            pos = i
            if escape {
                out.append((i, "\\" + String(c)))
                escape = false
            } else if c == "\\" {
                escape = true
            } else {
                out.append((i, String(c)))
            }
        }
        if escape { out.append((pos, "\\")) }
        return out
    }

    static func stripQuotedRealnames(_ addr: String) -> String {
        guard addr.unicodeScalars.contains("\"") else { return addr }
        let s = Array(addr.unicodeScalars)
        var start = 0
        var openPos: Int?
        var result = String.UnicodeScalarView()
        for (pos, ch) in escapedChars(s) where ch == "\"" {
            if openPos == nil {
                openPos = pos
            } else {
                if start != openPos! { result.append(contentsOf: s[start..<openPos!]) }
                start = pos + 1
                openPos = nil
            }
        }
        if start < s.count { result.append(contentsOf: s[start...]) }
        return String(result)
    }

    static func checkParenthesis(_ addr: String) -> Bool {
        let s = Array(stripQuotedRealnames(addr).unicodeScalars)
        var opens = 0
        for (_, ch) in escapedChars(s) {
            if ch == "(" {
                opens += 1
            } else if ch == ")" {
                opens -= 1
                if opens < 0 { return false }
            }
        }
        return opens == 0
    }
}

/// A port of `email._parseaddr.AddrlistClass`.
final class AddrlistParser {
    private let field: [Unicode.Scalar]
    private var pos = 0
    private var commentlist: [String] = []

    private static let specials = Set("()<>@,:;.\"[]".unicodeScalars)
    private static let lws = Set(" \t".unicodeScalars)
    private static let cr = Set("\r\n".unicodeScalars)
    private static let fws = lws.union(cr)
    private static let atomends = specials.union(lws).union(cr)
    private static let phraseends = atomends.subtracting(["."])

    init(_ field: String) { self.field = Array(field.unicodeScalars) }

    private var atEnd: Bool { pos >= field.count }
    private var current: Unicode.Scalar { field[pos] }

    @discardableResult
    private func gotonext() -> String {
        var ws = String.UnicodeScalarView()
        while !atEnd {
            if AddrlistParser.lws.contains(current) || current == "\n" || current == "\r" {
                if current != "\n" && current != "\r" { ws.append(current) }
                pos += 1
            } else if current == "(" {
                commentlist.append(getcomment())
            } else {
                break
            }
        }
        return String(ws)
    }

    func getaddrlist() -> [AddressPair] {
        var result: [AddressPair] = []
        while !atEnd {
            let ad = getaddress()
            if ad.isEmpty {
                result.append(AddressPair(name: "", address: ""))
            } else {
                result += ad
            }
        }
        return result
    }

    private func getaddress() -> [AddressPair] {
        commentlist = []
        gotonext()
        let oldpos = pos
        let oldcl = commentlist
        let plist = getphraselist()
        gotonext()
        var returnlist: [AddressPair] = []

        if atEnd {
            if let first = plist.first {
                returnlist = [AddressPair(name: commentlist.joined(separator: " "), address: first)]
            }
        } else if current == "." || current == "@" {
            pos = oldpos
            commentlist = oldcl
            let addrspec = getaddrspec()
            returnlist = [AddressPair(name: commentlist.joined(separator: " "), address: addrspec)]
        } else if current == ":" {
            pos += 1
            while !atEnd {
                gotonext()
                if !atEnd && current == ";" {
                    pos += 1
                    break
                }
                returnlist += getaddress()
            }
        } else if current == "<" {
            let routeaddr = getrouteaddr()
            if !commentlist.isEmpty {
                returnlist = [AddressPair(name: plist.joined(separator: " ") + " (" + commentlist.joined(separator: " ") + ")",
                                          address: routeaddr)]
            } else {
                returnlist = [AddressPair(name: plist.joined(separator: " "), address: routeaddr)]
            }
        } else {
            if let first = plist.first {
                returnlist = [AddressPair(name: commentlist.joined(separator: " "), address: first)]
            } else if AddrlistParser.specials.contains(current) {
                pos += 1
            }
        }
        gotonext()
        if !atEnd && current == "," { pos += 1 }
        return returnlist
    }

    private func getrouteaddr() -> String {
        guard !atEnd, current == "<" else { return "" }
        var expectroute = false
        pos += 1
        gotonext()
        var adlist = ""
        while !atEnd {
            if expectroute {
                _ = getdomain()
                expectroute = false
            } else if current == ">" {
                pos += 1
                break
            } else if current == "@" {
                pos += 1
                expectroute = true
            } else if current == ":" {
                pos += 1
            } else {
                adlist = getaddrspec()
                pos += 1
                break
            }
            gotonext()
        }
        return adlist
    }

    private func getaddrspec() -> String {
        var aslist: [String] = []
        gotonext()
        while !atEnd {
            var preserveWS = true
            if current == "." {
                if let last = aslist.last, last.pyStrip.isEmpty { aslist.removeLast() }
                aslist.append(".")
                pos += 1
                preserveWS = false
            } else if current == "\"" {
                aslist.append("\"" + MIMEParams.quote(getquote()) + "\"")
            } else if AddrlistParser.atomends.contains(current) {
                if let last = aslist.last, last.pyStrip.isEmpty { aslist.removeLast() }
                break
            } else {
                aslist.append(getatom())
            }
            let ws = gotonext()
            if preserveWS && !ws.isEmpty { aslist.append(ws) }
        }
        if atEnd || current != "@" { return aslist.joined() }
        aslist.append("@")
        pos += 1
        gotonext()
        let domain = getdomain()
        if domain.isEmpty { return "" }
        return aslist.joined() + domain
    }

    private func getdomain() -> String {
        var sdlist: [String] = []
        while !atEnd {
            if AddrlistParser.lws.contains(current) {
                pos += 1
            } else if current == "(" {
                commentlist.append(getcomment())
            } else if current == "[" {
                sdlist.append("[" + getdelimited("[", ends: ["]", "\r"], allowComments: false) + "]")
            } else if current == "." {
                pos += 1
                sdlist.append(".")
            } else if current == "@" {
                return ""
            } else if AddrlistParser.atomends.contains(current) {
                break
            } else {
                sdlist.append(getatom())
            }
        }
        return sdlist.joined()
    }

    private func getdelimited(_ begin: Unicode.Scalar, ends: Set<Unicode.Scalar>, allowComments: Bool) -> String {
        guard !atEnd, current == begin else { return "" }
        var out = ""
        var quote = false
        pos += 1
        while !atEnd {
            if quote {
                out.unicodeScalars.append(current)
                quote = false
            } else if ends.contains(current) {
                pos += 1
                break
            } else if allowComments && current == "(" {
                out += getcomment()
                continue
            } else if current == "\\" {
                quote = true
            } else {
                out.unicodeScalars.append(current)
            }
            pos += 1
        }
        return out
    }

    private func getquote() -> String { getdelimited("\"", ends: ["\"", "\r"], allowComments: false) }
    private func getcomment() -> String { getdelimited("(", ends: [")", "\r"], allowComments: true) }

    private func getatom(_ ends: Set<Unicode.Scalar>? = nil) -> String {
        let stop = ends ?? AddrlistParser.atomends
        var out = String.UnicodeScalarView()
        while !atEnd {
            if stop.contains(current) { break }
            out.append(current)
            pos += 1
        }
        return String(out)
    }

    private func getphraselist() -> [String] {
        var plist: [String] = []
        while !atEnd {
            if AddrlistParser.fws.contains(current) {
                pos += 1
            } else if current == "\"" {
                plist.append(getquote())
            } else if current == "(" {
                commentlist.append(getcomment())
            } else if AddrlistParser.phraseends.contains(current) {
                break
            } else {
                plist.append(getatom(AddrlistParser.phraseends))
            }
        }
        return plist
    }
}

// MARK: - Dates (email.utils.parsedate_to_datetime)

/// An absolute moment from a `Date:` header, with the offset it was written in.
public struct EmailDate: Hashable, Codable {
    /// Seconds since 1970-01-01 UTC.
    public let epoch: Int
    /// The header's UTC offset in seconds (0 for a naive date, which the tool
    /// treats as UTC).
    public let offset: Int
    /// The calendar day and wall-clock time as written (in `offset`).
    public let day: Day
    public let hour: Int
    public let minute: Int
    public let second: Int

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(epoch)) }

    /// `strftime("%Y-%m-%d %H:%M")` in the header's own offset.
    public var minuteString: String { day.iso + String(format: " %02d:%02d", hour, minute) }
}

public enum DateParsing {
    static let daynames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    static let monthnames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
                             "january", "february", "march", "april", "may", "june", "july", "august",
                             "september", "october", "november", "december"]
    static let timezones: [String: Int] = ["UT": 0, "UTC": 0, "GMT": 0, "Z": 0, "AST": -400, "ADT": -300,
                                           "EST": -500, "EDT": -400, "CST": -600, "CDT": -500, "MST": -700,
                                           "MDT": -600, "PST": -800, "PDT": -700]

    /// Python's `int(s)` for the strings that reach it here.
    static func pyInt(_ raw: String) -> Int? {
        var s = raw.pyStrip
        guard !s.isEmpty else { return nil }
        var sign = 1
        if s.hasPrefix("+") || s.hasPrefix("-") {
            if s.hasPrefix("-") { sign = -1 }
            s.removeFirst()
        }
        let digits = Array(s.unicodeScalars)
        guard !digits.isEmpty, PyText.isASCIIDigit(digits.first!), PyText.isASCIIDigit(digits.last!) else { return nil }
        var value = 0
        var previousUnderscore = false
        for d in digits {
            if d == "_" {
                if previousUnderscore { return nil }
                previousUnderscore = true
                continue
            }
            guard PyText.isASCIIDigit(d) else { return nil }
            previousUnderscore = false
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int(d.value - 0x30))
            if o1 || o2 { return nil }
            value = a
        }
        return sign * value
    }

    /// `email._parseaddr._parsedate_tz`: (y, m, d, H, M, S, offset seconds or nil).
    static func parsedateTZ(_ input: String) -> (Int, Int, Int, Int, Int, Int, Int?)? {
        var data = input.pyWords
        guard !data.isEmpty else { return nil }
        if data[0].hasSuffix(",") || daynames.contains(data[0].lowercased()) {
            data.removeFirst()
        } else if let comma = data[0].unicodeScalars.lastIndex(of: ",") {
            data[0] = String(data[0].unicodeScalars[data[0].unicodeScalars.index(after: comma)...])
        }
        if data.count == 3 {
            let stuff = data[0].pySplit("-")
            if stuff.count == 3 { data = stuff + data[1...] }
        }
        if data.count == 4 {
            let s = data[3]
            var i = s.unicodeScalars.firstIndex(of: "+").map { s.unicodeScalars.distance(from: s.unicodeScalars.startIndex, to: $0) } ?? -1
            if i == -1 {
                i = s.unicodeScalars.firstIndex(of: "-").map { s.unicodeScalars.distance(from: s.unicodeScalars.startIndex, to: $0) } ?? -1
            }
            if i > 0 {
                data = Array(data[0..<3]) + [s.pyPrefix(i), s.pyDropFirst(i)]
            } else {
                data.append("")
            }
        }
        guard data.count >= 5 else { return nil }
        var dd = data[0], mm = data[1], yy = data[2], tm = data[3], tz = data[4]
        guard !dd.isEmpty, !mm.isEmpty, !yy.isEmpty else { return nil }
        mm = mm.lowercased()
        if !monthnames.contains(mm) {
            (dd, mm) = (mm, dd.lowercased())
            if !monthnames.contains(mm) { return nil }
        }
        var month = monthnames.firstIndex(of: mm)! + 1
        if month > 12 { month -= 12 }
        if dd.hasSuffix(",") { dd = dd.pyPrefix(-1) }
        if let colon = yy.unicodeScalars.firstIndex(of: ":"), colon != yy.unicodeScalars.startIndex {
            (yy, tm) = (tm, yy)
        }
        if yy.hasSuffix(",") {
            yy = yy.pyPrefix(-1)
            if yy.isEmpty { return nil }
        }
        if let first = yy.unicodeScalars.first, !PyText.isASCIIDigit(first) {
            (yy, tz) = (tz, yy)
        }
        guard !tm.isEmpty else { return nil }  // Python raises IndexError here
        if tm.hasSuffix(",") { tm = tm.pyPrefix(-1) }
        var parts = tm.pySplit(":")
        var thh: String, tmm: String, tss: String
        if parts.count == 2 {
            thh = parts[0]; tmm = parts[1]; tss = "0"
        } else if parts.count == 3 {
            thh = parts[0]; tmm = parts[1]; tss = parts[2]
        } else if parts.count == 1 && tm.contains(".") {
            parts = tm.pySplit(".")
            if parts.count == 2 {
                thh = parts[0]; tmm = parts[1]; tss = "0"
            } else if parts.count == 3 {
                thh = parts[0]; tmm = parts[1]; tss = parts[2]
            } else {
                return nil
            }
        } else {
            return nil
        }
        guard var year = pyInt(yy), let day = pyInt(dd), let hour = pyInt(thh),
              let minute = pyInt(tmm), let second = pyInt(tss) else { return nil }
        if year < 100 { year += year > 68 ? 1900 : 2000 }
        var tzoffset: Int?
        let tzUpper = tz.uppercased()
        if let named = timezones[tzUpper] {
            tzoffset = named
        } else {
            tzoffset = pyInt(tzUpper)
            if tzoffset == 0 && tzUpper.hasPrefix("-") { tzoffset = nil }
        }
        if let t = tzoffset, t != 0 {
            let sign = t < 0 ? -1 : 1
            let a = abs(t)
            tzoffset = sign * ((a / 100) * 3600 + (a % 100) * 60)
        }
        return (year, month, day, hour, minute, second, tzoffset)
    }

    /// `parsedate_to_datetime`, then the `get_email_date` convention that a
    /// naive result is UTC. Nil where Python raises (the caller then uses
    /// "now", as the tool does).
    public static func parse(_ header: HeaderValue?) -> EmailDate? {
        guard let header, !header.eightBit else { return nil }
        return parse(header.text)
    }

    public static func parse(_ text: String) -> EmailDate? {
        guard !text.isEmpty, let t = parsedateTZ(text) else { return nil }
        let (y, m, d, hh, mi, ss, tz) = t
        guard let day = Day(validYear: y, month: m, day: d), (0...23).contains(hh), (0...59).contains(mi),
              (0...59).contains(ss) else { return nil }
        let offset = tz ?? 0
        guard abs(offset) < 86400 else { return nil }
        let epochDay = Day(year: 1970, month: 1, day: 1).ordinal
        let epoch = (day.ordinal - epochDay) * 86400 + hh * 3600 + mi * 60 + ss - offset
        return EmailDate(epoch: epoch, offset: offset, day: day, hour: hh, minute: mi, second: ss)
    }

    /// The fallback `get_email_date` uses for a missing or bad header: now, UTC.
    public static func now(_ date: Date = Date()) -> EmailDate {
        let epoch = Int(date.timeIntervalSince1970.rounded(.down))
        let days = Int((Double(epoch) / 86400).rounded(.down))
        let secs = epoch - days * 86400
        let day = Day(ordinal: Day(year: 1970, month: 1, day: 1).ordinal + days)
        return EmailDate(epoch: epoch, offset: 0, day: day, hour: secs / 3600, minute: (secs % 3600) / 60,
                         second: secs % 60)
    }
}
