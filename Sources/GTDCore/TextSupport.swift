import Foundation

// Small helpers that let the ported Python code be written almost
// line-for-line with the same semantics. They work on Unicode scalars (code
// points), as Python strings do: Swift's `Character` would merge "\r\n" and
// emoji sequences into one element and change the results.

enum PyText {
    /// Code points for which Python's `str.isspace()` is true.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// Line boundaries recognised by Python's `str.splitlines()`.
    static func isLineBreak(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    static func isASCIIDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }

    static func isASCIIAlnum(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x30 && s.value <= 0x39) || (s.value >= 0x41 && s.value <= 0x5A)
            || (s.value >= 0x61 && s.value <= 0x7A)
    }
}

extension String {
    /// Python's `str.strip()`.
    var pyStrip: String {
        let scalars = Array(unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end && PyText.isSpace(scalars[start]) { start += 1 }
        while end > start && PyText.isSpace(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    /// Python's `str.lstrip()`.
    var pyLStrip: String {
        let scalars = Array(unicodeScalars)
        var start = 0
        while start < scalars.count && PyText.isSpace(scalars[start]) { start += 1 }
        return String(String.UnicodeScalarView(scalars[start...]))
    }

    /// Python's `str.rstrip(chars)` for a set of code points.
    func pyRStrip(_ chars: Set<Unicode.Scalar>) -> String {
        var scalars = Array(unicodeScalars)
        while let last = scalars.last, chars.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Python's `str.lstrip(chars)` for a set of code points.
    func pyLStrip(_ chars: Set<Unicode.Scalar>) -> String {
        let scalars = Array(unicodeScalars)
        var start = 0
        while start < scalars.count && chars.contains(scalars[start]) { start += 1 }
        return String(String.UnicodeScalarView(scalars[start...]))
    }

    /// Python's `str.strip(chars)` for a set of code points.
    func pyStrip(_ chars: Set<Unicode.Scalar>) -> String {
        let scalars = Array(unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end && chars.contains(scalars[start]) { start += 1 }
        while end > start && chars.contains(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    /// Python's `str.isspace()` (false for the empty string).
    var pyIsSpace: Bool { !isEmpty && unicodeScalars.allSatisfy(PyText.isSpace) }

    /// Python's whitespace `str.split()` (runs of whitespace, no empty items).
    var pyWords: [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for s in unicodeScalars {
            if PyText.isSpace(s) {
                if !current.isEmpty { words.append(String(current)); current = String.UnicodeScalarView() }
            } else {
                current.append(s)
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// Python's `str.splitlines()` (no line ends kept, no trailing empty item).
    var pySplitLines: [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var iterator = unicodeScalars.makeIterator()
        var pending = iterator.next()
        while let s = pending {
            pending = iterator.next()
            if PyText.isLineBreak(s) {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                if s == "\r", pending == "\n" { pending = iterator.next() }
            } else {
                current.append(s)
            }
        }
        if !current.isEmpty { lines.append(String(current)) }
        return lines
    }

    /// Python's `s.split(sep)` for a single-scalar separator.
    func pySplit(_ sep: Unicode.Scalar) -> [String] {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        for s in unicodeScalars {
            if s == sep {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(s)
            }
        }
        parts.append(String(current))
        return parts
    }

    /// Number of code points (Python's `len`).
    var pyCount: Int { unicodeScalars.count }

    /// Python's `s[:n]`: the first `n` code points (n < 0 counts from the end).
    func pyPrefix(_ n: Int) -> String {
        let count = unicodeScalars.count
        let k = n < 0 ? max(0, count + n) : min(n, count)
        return String(String.UnicodeScalarView(unicodeScalars.prefix(k)))
    }

    /// Python's `s[n:]`.
    func pyDropFirst(_ n: Int) -> String {
        String(String.UnicodeScalarView(unicodeScalars.dropFirst(max(0, n))))
    }

    /// Python's `s.lower()` (full Unicode lower-casing).
    var pyLower: String { lowercased() }

    /// Text as Python reads it from a file opened in text mode ("universal
    /// newlines"): "\r\n" and lone "\r" become "\n".
    var universalNewlines: String {
        guard unicodeScalars.contains("\r") else { return self }
        var out = String.UnicodeScalarView()
        var iterator = unicodeScalars.makeIterator()
        var pending = iterator.next()
        while let s = pending {
            pending = iterator.next()
            if s == "\r" {
                out.append("\n")
                if pending == "\n" { pending = iterator.next() }
            } else {
                out.append(s)
            }
        }
        return String(out)
    }
}

/// Python's default string ordering (`sorted()` on `str`): by code point.
/// Swift's `<` on `String` compares canonically-equivalent forms instead.
public func codePointPrecedes(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
}

/// A thin wrapper around `NSRegularExpression` so the ported Python helpers
/// can be written almost line-for-line. Patterns are compiled once (callers
/// keep instances in `static let`s) and a bad pattern is a programmer error.
struct Rx {
    let regex: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            fatalError("Invalid regular expression \(pattern): \(error)")
        }
    }

    private func fullRange(_ s: String) -> NSRange {
        NSRange(location: 0, length: (s as NSString).length)
    }

    /// `re.sub(pattern, template, s)`. `template` may use `$1` group refs.
    func replace(_ s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, options: [], range: fullRange(s), withTemplate: template)
    }

    /// `re.sub(pattern, fn, s)`: replace each match with `transform(match)`.
    func replace(_ s: String, using transform: (RxMatch) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in regex.matches(in: s, options: [], range: fullRange(s)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += transform(RxMatch(result: m, source: ns))
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// `bool(re.search(pattern, s))`.
    func matches(_ s: String) -> Bool {
        regex.firstMatch(in: s, options: [], range: fullRange(s)) != nil
    }

    /// `re.search` (or `re.match` for a pattern anchored with `^`).
    func firstMatch(_ s: String) -> RxMatch? {
        guard let m = regex.firstMatch(in: s, options: [], range: fullRange(s)) else { return nil }
        return RxMatch(result: m, source: s as NSString)
    }

    /// `re.findall` / `re.finditer`.
    func allMatches(_ s: String) -> [RxMatch] {
        let ns = s as NSString
        return regex.matches(in: s, options: [], range: fullRange(s)).map { RxMatch(result: $0, source: ns) }
    }

    /// `re.split(pattern, s)`, including capture groups in the result as
    /// Python does (a group that did not take part yields "").
    func split(_ s: String) -> [String] {
        let ns = s as NSString
        var parts: [String] = []
        var cursor = 0
        for m in regex.matches(in: s, options: [], range: fullRange(s)) {
            parts.append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            if m.numberOfRanges > 1 {
                for g in 1..<m.numberOfRanges {
                    let r = m.range(at: g)
                    parts.append(r.location == NSNotFound ? "" : ns.substring(with: r))
                }
            }
            cursor = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: cursor))
        return parts
    }
}

/// One regular-expression match, with Python-style group access.
struct RxMatch {
    let result: NSTextCheckingResult
    let source: NSString

    /// Text of group `index` (0 = whole match), or nil if it did not take part.
    func group(_ index: Int) -> String? {
        guard index < result.numberOfRanges else { return nil }
        let r = result.range(at: index)
        guard r.location != NSNotFound else { return nil }
        return source.substring(with: r)
    }

    /// UTF-16 offset just past the match (for `s[m.end():]`).
    var end: Int { result.range.location + result.range.length }
    var start: Int { result.range.location }
}

/// Atomically write UTF-8 text, creating the parent folder first.
func writeTextAtomically(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
}

/// Read a file as UTF-8, replacing invalid sequences. Returns nil when the
/// file cannot be read at all. No newline translation.
func readTextFile(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// A calendar day with no time or zone, like Python's `datetime.date`.
public struct Day: Hashable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// `date.fromisoformat` for the strict `yyyy-mm-dd` form (the only form
    /// the workflow writes). Returns nil for anything else or an invalid date.
    public init?(iso: String) {
        let s = Array(iso.unicodeScalars)
        guard s.count == 10, s[4] == "-", s[7] == "-" else { return nil }
        for i in [0, 1, 2, 3, 5, 6, 8, 9] where !PyText.isASCIIDigit(s[i]) { return nil }
        let text = iso
        guard let y = Int(text.pyPrefix(4)), let m = Int(text.pyDropFirst(5).pyPrefix(2)),
              let d = Int(text.pyDropFirst(8)) else { return nil }
        self.init(validYear: y, month: m, day: d)
    }

    /// A day only if it exists on the proleptic Gregorian calendar.
    public init?(validYear y: Int, month m: Int, day d: Int) {
        guard y >= 1, y <= 9999, m >= 1, m <= 12, d >= 1, d <= Day.daysIn(year: y, month: m) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    public static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeap(year) ? 29 : 28
        }
    }

    /// Days since 0001-01-01 (Python's `toordinal() - 1`).
    public var ordinal: Int {
        let y = year - 1
        var days = y * 365 + y / 4 - y / 100 + y / 400
        for m in 1..<month { days += Day.daysIn(year: year, month: m) }
        return days + day - 1
    }

    public init(ordinal: Int) {
        // Walk years in 400-year cycles, then single years and months.
        var n = ordinal
        var y = 1
        let cycle = 146097
        y += 400 * (n / cycle)
        n %= cycle
        while true {
            let len = Day.isLeap(y) ? 366 : 365
            if n < len { break }
            n -= len
            y += 1
        }
        var m = 1
        while n >= Day.daysIn(year: y, month: m) {
            n -= Day.daysIn(year: y, month: m)
            m += 1
        }
        self.init(year: y, month: m, day: n + 1)
    }

    public func adding(days: Int) -> Day { Day(ordinal: ordinal + days) }

    /// `(self - other).days`.
    public func days(since other: Day) -> Int { ordinal - other.ordinal }

    /// Monday = 0 … Sunday = 6, as Python's `weekday()`.
    public var weekday: Int { ordinal % 7 }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    public static func < (a: Day, b: Day) -> Bool { a.ordinal < b.ordinal }

    /// Today in the given time zone (the local zone by default).
    public static func today(in zone: TimeZone = .current, now: Date = Date()) -> Day {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: now)
        return Day(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }
}
