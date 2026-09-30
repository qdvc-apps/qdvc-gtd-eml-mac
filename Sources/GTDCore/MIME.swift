import Foundation

// A port of the parts of Python's `email` package that qdvc-gtd-eml relies
// on, with its default `compat32` policy: `message_from_binary_file` (the
// feed parser), `Message.get` / `get_all` / `get_param` / `get_filename` /
// `get_content_charset` / `get_payload(decode=True)` / `walk`, and
// `email.header.decode_header` + `make_header`.
//
// Behaviour worth knowing (all reproduced from Python, and pinned by the
// parity fixture):
//   * The file is read as ASCII with surrogate escapes and universal
//     newlines, so every "\r\n" and lone "\r" becomes "\n" before parsing.
//   * A header containing raw 8-bit bytes is not decoded at all: each byte
//     above 0x7F becomes U+FFFD, and RFC 2047 words in it are left as-is.
//   * Header values keep their folding ("Subject: a\n b" is "a\n b").
//   * Any failure while decoding RFC 2047 words (unknown charset, invalid
//     bytes, bad base64) returns the raw header, stripped.

/// A header value as the compat32 policy returns it.
public struct HeaderValue: Hashable {
    /// The value; for an 8-bit header, with each high byte replaced by U+FFFD.
    public let text: String
    /// True when the raw header contained bytes above 0x7F (Python returns a
    /// `Header` object for these rather than a `str`).
    public let eightBit: Bool
}

/// A parameter value from `get_param`: plain, or RFC 2231 extended.
enum ParamValue {
    case plain(String)
    case extended(charset: String?, language: String?, value: String)
}

/// One MIME entity (`email.message.Message`).
public final class MIMEEntity {
    var headers: [(name: String, value: HeaderValue)] = []
    /// The raw payload of a leaf entity (after newline translation).
    var payload: [UInt8] = []
    /// Sub-entities; non-nil exactly when Python's `is_multipart()` is true.
    var children: [MIMEEntity]?
    var defaultType = "text/plain"

    public var isMultipart: Bool { children != nil }

    /// `Message.get(name)`: the first header of that name.
    public func get(_ name: String) -> HeaderValue? {
        let key = name.lowercased()
        return headers.first { $0.name.lowercased() == key }?.value
    }

    /// `Message.get_all(name, [])`.
    public func getAll(_ name: String) -> [HeaderValue] {
        let key = name.lowercased()
        return headers.filter { $0.name.lowercased() == key }.map(\.value)
    }

    public func has(_ name: String) -> Bool { get(name) != nil }

    /// `get_content_type()`.
    public var contentType: String {
        guard let value = get("content-type") else { return defaultType }
        let ctype = MIMEParams.splitParam(value.text).lowercased()
        if ctype.unicodeScalars.filter({ $0 == "/" }).count != 1 { return "text/plain" }
        return ctype
    }

    public var mainType: String { contentType.pySplit("/")[0] }

    /// `walk()`: this entity, then every descendant, depth first.
    public func walk() -> [MIMEEntity] {
        var out: [MIMEEntity] = [self]
        for child in children ?? [] { out.append(contentsOf: child.walk()) }
        return out
    }

    /// `get_param(name, header=...)`, unquoted as Python does by default.
    func param(_ name: String, header: String = "content-type") -> ParamValue? {
        guard let value = get(header) else { return nil }
        let key = name.lowercased()
        for (k, v) in MIMEParams.paramsPreserve(value.text) where k.lowercased() == key {
            switch v {
            case .plain(let s): return .plain(MIMEParams.unquote(s))
            case .extended(let c, let l, let s): return .extended(charset: c, language: l, value: MIMEParams.unquote(s))
            }
        }
        return nil
    }

    /// `get_content_charset()`: lower-cased, or nil.
    public var contentCharset: String? {
        guard let p = param("charset") else { return nil }
        var charset: String
        switch p {
        case .plain(let s):
            charset = s
        case .extended(let c, _, let s):
            let pcharset = (c?.isEmpty ?? true) ? "us-ascii" : c!
            if let decoded = Charsets.decode(MIMEParams.rawUnicodeEscape(s), charset: pcharset, strict: true) {
                charset = decoded
            } else {
                charset = s
            }
        }
        guard charset.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return charset.lowercased()
    }

    /// `get_filename()`.
    public var filename: String? {
        let p = param("filename", header: "content-disposition") ?? param("name", header: "content-type")
        guard let p else { return nil }
        return MIMEParams.collapseRFC2231(p).pyStrip
    }

    /// `get_boundary()`.
    var boundary: String? {
        guard let p = param("boundary") else { return nil }
        return MIMEParams.collapseRFC2231(p).pyRStrip(Set(" \t\n\r\u{0B}\u{0C}".unicodeScalars))
    }

    /// `get_payload(decode=True)`: nil for a container, otherwise the bytes
    /// with the transfer encoding undone.
    public func decodedPayload() -> [UInt8]? {
        guard children == nil else { return nil }
        let cte = (get("content-transfer-encoding")?.text ?? "").lowercased()
        switch cte {
        case "quoted-printable":
            return TransferEncoding.decodeQuotedPrintable(payload)
        case "base64":
            let joined = payload.filter { $0 != 0x0A && $0 != 0x0D }
            return TransferEncoding.decodeBase64(joined) ?? joined
        default:
            return payload
        }
    }
}

// MARK: - Parsing

public enum MIMEParser {
    /// `email.message_from_binary_file`.
    public static func parse(_ data: Data) -> MIMEEntity {
        parse([UInt8](data))
    }

    public static func parse(_ raw: [UInt8]) -> MIMEEntity {
        let reader = LineReader(lines: splitLines(universalNewlines(raw)))
        let parser = FeedParser(reader: reader)
        return parser.parseEntity(defaultType: "text/plain")
    }

    /// "\r\n" and "\r" to "\n", as Python's text-mode read does.
    static func universalNewlines(_ raw: [UInt8]) -> [UInt8] {
        guard raw.contains(0x0D) else { return raw }
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var i = 0
        while i < raw.count {
            let b = raw[i]
            if b == 0x0D {
                out.append(0x0A)
                if i + 1 < raw.count, raw[i + 1] == 0x0A { i += 1 }
            } else {
                out.append(b)
            }
            i += 1
        }
        return out
    }

    /// Lines, each keeping its trailing "\n" (the last may lack one).
    static func splitLines(_ bytes: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var start = 0
        for (i, b) in bytes.enumerated() where b == 0x0A {
            lines.append(Array(bytes[start...i]))
            start = i + 1
        }
        if start < bytes.count { lines.append(Array(bytes[start...])) }
        return lines
    }

    /// Bytes as text the way compat32 hands a header back.
    static func headerText(_ bytes: [UInt8]) -> HeaderValue {
        var out = String.UnicodeScalarView()
        var eightBit = false
        for b in bytes {
            if b < 0x80 {
                out.append(Unicode.Scalar(b))
            } else {
                eightBit = true
                out.append("\u{FFFD}")
            }
        }
        return HeaderValue(text: String(out), eightBit: eightBit)
    }
}

/// Python's `BufferedSubFile`: lines with push-back and a stack of
/// end-of-part matchers (a line matching any of them reads as EOF and is not
/// consumed).
final class LineReader {
    private var lines: [[UInt8]]
    private var index = 0
    var eofStack: [([UInt8]) -> Bool] = []

    init(lines: [[UInt8]]) { self.lines = lines }

    func readline() -> [UInt8]? {
        guard index < lines.count else { return nil }
        let line = lines[index]
        for matcher in eofStack.reversed() where matcher(line) { return nil }
        index += 1
        return line
    }

    func unread() { index -= 1 }

    /// Push a line back so it is read next.
    func pushBack(_ line: [UInt8]) { lines.insert(line, at: index) }

    /// Read (and discard) until EOF or an end-of-part matcher.
    func drain() { while readline() != nil {} }
}

/// The recursive part of `email.feedparser.FeedParser._parsegen`.
final class FeedParser {
    let reader: LineReader
    /// Python's `_last`: the most recently created (or finished) entity,
    /// whose payload loses its final newline to the next boundary.
    private var last: MIMEEntity?

    init(reader: LineReader) { self.reader = reader }

    func parseEntity(defaultType: String) -> MIMEEntity {
        let entity = MIMEEntity()
        entity.defaultType = defaultType
        last = entity

        var headerLines: [[UInt8]] = []
        while let line = reader.readline() {
            if !FeedParser.isHeaderLine(line) {
                if line.first != 0x0A { reader.unread() }  // no blank separator
                break
            }
            headerLines.append(line)
        }
        parseHeaders(headerLines, into: entity)

        let ctype = entity.contentType
        if entity.mainType == "message" && ctype != "message/delivery-status" {
            let inner = parseEntity(defaultType: "text/plain")
            entity.children = [inner]
            return entity
        }
        if entity.mainType == "multipart", let boundary = entity.boundary {
            parseMultipart(entity, boundary: boundary)
            return entity
        }
        var body: [UInt8] = []
        while let line = reader.readline() { body.append(contentsOf: line) }
        entity.payload = body
        return entity
    }

    /// `^(From |[\041-\071\073-\176]*:|[\t ])`
    static func isHeaderLine(_ line: [UInt8]) -> Bool {
        if line.starts(with: Array("From ".utf8)) { return true }
        if let first = line.first, first == 0x20 || first == 0x09 { return true }
        var i = 0
        while i < line.count, (0x21...0x39).contains(line[i]) || (0x3B...0x7E).contains(line[i]) { i += 1 }
        return i < line.count && line[i] == 0x3A
    }

    private func parseHeaders(_ lines: [[UInt8]], into entity: MIMEEntity) {
        var lastHeader: [UInt8] = []
        var lastValue: [[UInt8]] = []

        func setRaw() {
            guard let first = lastValue.first, let colon = first.firstIndex(of: 0x3A) else { return }
            let name = String(decoding: first[..<colon], as: UTF8.self)
            var value = Array(first[(colon + 1)...])
            while let b = value.first, b == 0x20 || b == 0x09 { value.removeFirst() }
            for continuation in lastValue.dropFirst() { value.append(contentsOf: continuation) }
            while let b = value.last, b == 0x0A || b == 0x0D { value.removeLast() }
            entity.headers.append((name: name, value: MIMEParser.headerText(value)))
        }

        for (lineno, line) in lines.enumerated() {
            if let first = line.first, first == 0x20 || first == 0x09 {
                if lastHeader.isEmpty { continue }  // continuation with no header
                lastValue.append(line)
                continue
            }
            if !lastHeader.isEmpty {
                setRaw()
                lastHeader = []
                lastValue = []
            }
            if line.starts(with: Array("From ".utf8)) {
                if lineno == 0 { continue }  // Unix envelope line
                if lineno == lines.count - 1 {
                    reader.pushBack(line)  // probably the body's first line
                    return
                }
                continue  // misplaced envelope line
            }
            guard let colon = line.firstIndex(of: 0x3A), colon > 0 else { continue }
            lastHeader = Array(line[..<colon])
            lastValue = [line]
        }
        if !lastHeader.isEmpty { setRaw() }
    }

    /// Match a boundary line: `--boundary(--)?[ \t]*\n?$`. Returns nil when
    /// the line is not a boundary, otherwise whether it is the close one.
    static func boundaryMatch(_ line: [UInt8], separator: [UInt8]) -> Bool? {
        guard line.starts(with: separator) else { return nil }
        let rest = Array(line[separator.count...])
        func tail(from start: Int) -> Bool {
            var i = start
            while i < rest.count, rest[i] == 0x20 || rest[i] == 0x09 { i += 1 }
            if i < rest.count, rest[i] == 0x0A { i += 1 }
            return i == rest.count
        }
        if rest.count >= 2, rest[0] == 0x2D, rest[1] == 0x2D, tail(from: 2) { return true }
        if tail(from: 0) { return false }
        return nil
    }

    private func parseMultipart(_ entity: MIMEEntity, boundary: String) {
        let separator = Array("--".utf8) + Array(boundary.utf8)
        let match: ([UInt8]) -> Bool = { FeedParser.boundaryMatch($0, separator: separator) != nil }
        let childDefault = entity.contentType == "multipart/digest" ? "message/rfc822" : "text/plain"

        var capturingPreamble = true
        var preamble: [UInt8] = []
        var children: [MIMEEntity] = []

        while let line = reader.readline() {
            if let isClose = FeedParser.boundaryMatch(line, separator: separator) {
                if isClose { break }
                if capturingPreamble {
                    capturingPreamble = false
                    reader.unread()
                    continue
                }
                // Consume any run of boundary lines, then parse one part.
                while let next = reader.readline() {
                    if !match(next) { reader.unread(); break }
                }
                reader.eofStack.append(match)
                let child = parseEntity(defaultType: childDefault)
                if let previous = self.last, previous.mainType != "multipart", previous.children == nil {
                    // RFC 2046: the newline before a boundary belongs to it.
                    if previous.payload.last == 0x0A { previous.payload.removeLast() }
                }
                reader.eofStack.removeLast()
                children.append(child)
                last = entity
            } else {
                preamble.append(contentsOf: line)
            }
        }
        reader.drain()  // the epilogue (or, with no start boundary, the rest)
        if capturingPreamble {
            entity.payload = preamble  // start boundary never found
            return
        }
        entity.children = children
    }
}

// MARK: - Parameters (email.message._parseparam and email.utils)

enum MIMEParams {
    /// `_splitparam(value)[0]`.
    static func splitParam(_ value: String) -> String {
        if let semi = value.unicodeScalars.firstIndex(of: ";") {
            return String(value.unicodeScalars[..<semi]).pyStrip
        }
        return value.pyStrip
    }

    /// `_parseparam`.
    static func parseParam(_ value: String) -> [String] {
        var s = Array((";" + value).unicodeScalars)
        var plist: [String] = []
        func count(_ needle: [Unicode.Scalar], in slice: ArraySlice<Unicode.Scalar>) -> Int {
            guard !needle.isEmpty, slice.count >= needle.count else { return 0 }
            var n = 0
            var i = slice.startIndex
            while i <= slice.endIndex - needle.count {
                if Array(slice[i..<(i + needle.count)]) == needle {
                    n += 1
                    i += needle.count
                } else {
                    i += 1
                }
            }
            return n
        }
        func find(_ c: Unicode.Scalar, from start: Int) -> Int {
            var i = start
            while i < s.count { if s[i] == c { return i }; i += 1 }
            return -1
        }
        while s.first == ";" {
            s.removeFirst()
            var end = find(";", from: 0)
            while end > 0 && (count(["\""], in: s[0..<end]) - count(["\\", "\""], in: s[0..<end])) % 2 != 0 {
                end = find(";", from: end + 1)
            }
            if end < 0 { end = s.count }
            var f = String(String.UnicodeScalarView(s[0..<end]))
            if let eq = f.unicodeScalars.firstIndex(of: "=") {
                let name = String(f.unicodeScalars[..<eq]).pyStrip.lowercased()
                let rest = String(f.unicodeScalars[f.unicodeScalars.index(after: eq)...]).pyStrip
                f = name + "=" + rest
            }
            plist.append(f.pyStrip)
            s = Array(s[end...])
        }
        return plist
    }

    /// `_get_params_preserve` + `utils.decode_params`.
    static func paramsPreserve(_ value: String) -> [(String, ParamValue)] {
        var params: [(String, String)] = []
        for p in parseParam(value) {
            if let eq = p.unicodeScalars.firstIndex(of: "=") {
                params.append((String(p.unicodeScalars[..<eq]).pyStrip,
                               String(p.unicodeScalars[p.unicodeScalars.index(after: eq)...]).pyStrip))
            } else {
                params.append((p.pyStrip, ""))
            }
        }
        guard let first = params.first else { return [] }
        var out: [(String, ParamValue)] = [(first.0, .plain(first.1))]
        var rfc2231: [(name: String, parts: [(num: Int?, value: String, encoded: Bool)])] = []
        for (name, raw) in params.dropFirst() {
            let encoded = name.hasSuffix("*")
            let value = unquote(raw)
            if let m = continuationRx.firstMatch(name), let base = m.group(1) {
                let num = m.group(3).flatMap { Int($0) }
                if let i = rfc2231.firstIndex(where: { $0.name == base }) {
                    rfc2231[i].parts.append((num, value, encoded))
                } else {
                    rfc2231.append((base, [(num, value, encoded)]))
                }
            } else {
                out.append((name, .plain("\"" + quote(value) + "\"")))
            }
        }
        for (name, parts) in rfc2231 {
            let sorted = parts.sorted { ($0.num ?? -1) < ($1.num ?? -1) }
            var extended = false
            var pieces: [String] = []
            for part in sorted {
                if part.encoded {
                    pieces.append(percentDecodeLatin1(part.value))
                    extended = true
                } else {
                    pieces.append(part.value)
                }
            }
            let joined = quote(pieces.joined())
            if extended {
                let bits = joined.pySplit("'")
                if bits.count <= 2 {
                    out.append((name, .extended(charset: nil, language: nil, value: "\"" + joined + "\"")))
                } else {
                    let rest = bits[2...].joined(separator: "'")
                    out.append((name, .extended(charset: bits[0], language: bits[1], value: "\"" + rest + "\"")))
                }
            } else {
                out.append((name, .plain("\"" + joined + "\"")))
            }
        }
        return out
    }

    static let continuationRx = Rx("^([A-Za-z0-9_]+)\\*(([0-9]+)\\*?)?$")

    /// `email.utils.unquote`.
    static func unquote(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count > 1 else { return s }
        if scalars.first == "\"" && scalars.last == "\"" {
            let inner = String(String.UnicodeScalarView(scalars[1..<(scalars.count - 1)]))
            return inner.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
        }
        if scalars.first == "<" && scalars.last == ">" {
            return String(String.UnicodeScalarView(scalars[1..<(scalars.count - 1)]))
        }
        return s
    }

    /// `email.utils.quote`.
    static func quote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `utils.collapse_rfc2231_value(value)` applied to a `get_param` result.
    static func collapseRFC2231(_ p: ParamValue) -> String {
        switch p {
        case .plain(let s):
            return unquote(s)
        case .extended(let charset, _, let text):
            let cs = (charset?.isEmpty ?? true) ? "us-ascii" : charset!
            if Charsets.isKnown(cs) {
                return Charsets.decode(rawUnicodeEscape(text), charset: cs, strict: false) ?? unquote(text)
            }
            return unquote(text)
        }
    }

    /// `urllib.parse.unquote(s, encoding="latin-1")`.
    static func percentDecodeLatin1(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func hex(_ c: Unicode.Scalar) -> UInt8? {
            switch c.value {
            case 0x30...0x39: return UInt8(c.value - 0x30)
            case 0x41...0x46: return UInt8(c.value - 0x41 + 10)
            case 0x61...0x66: return UInt8(c.value - 0x61 + 10)
            default: return nil
            }
        }
        while i < scalars.count {
            if scalars[i] == "%", i + 2 < scalars.count,
               let hi = hex(scalars[i + 1]), let lo = hex(scalars[i + 2]) {
                out.append(Unicode.Scalar(hi << 4 | lo))
                i += 3
            } else {
                out.append(scalars[i])
                i += 1
            }
        }
        return String(out)
    }

    /// `bytes(s, "raw-unicode-escape")` for the text that reaches it here
    /// (code points up to U+00FF map to one byte; others are escaped).
    static func rawUnicodeEscape(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in s.unicodeScalars {
            if scalar.value < 0x100 {
                out.append(UInt8(scalar.value))
            } else if scalar.value < 0x10000 {
                out.append(contentsOf: Array(String(format: "\\u%04x", scalar.value).utf8))
            } else {
                out.append(contentsOf: Array(String(format: "\\U%08x", scalar.value).utf8))
            }
        }
        return out
    }
}

// MARK: - Transfer encodings

enum TransferEncoding {
    /// `binascii.a2b_qp` (body mode).
    static func decodeQuotedPrintable(_ data: [UInt8]) -> [UInt8] {
        func hexval(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = 0
        let n = data.count
        while i < n {
            let b = data[i]
            if b == 0x3D {  // "="
                i += 1
                if i >= n { break }
                if data[i] == 0x0A || data[i] == 0x0D {
                    if data[i] != 0x0A {
                        while i < n && data[i] != 0x0A { i += 1 }
                    }
                    if i < n { i += 1 }
                } else if data[i] == 0x3D {
                    out.append(0x3D)
                    i += 1
                } else if i + 1 < n, let hi = hexval(data[i]), let lo = hexval(data[i + 1]) {
                    out.append(hi << 4 | lo)
                    i += 2
                } else {
                    out.append(0x3D)
                }
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    /// Lenient base64 (`binascii.a2b_base64` in non-strict mode, plus the
    /// padding repair `email._encoded_words.decode_b` applies). Returns nil
    /// when the data cannot be decoded at all (one stray sextet).
    static func decodeBase64(_ data: [UInt8]) -> [UInt8]? {
        func value(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x41...0x5A: return b - 0x41
            case 0x61...0x7A: return b - 0x61 + 26
            case 0x30...0x39: return b - 0x30 + 52
            case 0x2B: return 62
            case 0x2F: return 63
            default: return nil
            }
        }
        var out: [UInt8] = []
        var quad: [UInt8] = []
        func flush() {
            if quad.count >= 2 { out.append(quad[0] << 2 | quad[1] >> 4) }
            if quad.count >= 3 { out.append((quad[1] & 0x0F) << 4 | quad[2] >> 2) }
            if quad.count >= 4 { out.append((quad[2] & 0x03) << 6 | quad[3]) }
            quad.removeAll(keepingCapacity: true)
        }
        var pads = 0
        for b in data {
            if b == 0x3D {
                // Enough "=" to complete a partial quad ends the data, as
                // in CPython; anything after it is ignored.
                if quad.count >= 2 {
                    pads += 1
                    if quad.count + pads >= 4 {
                        flush()
                        return out
                    }
                }
                continue
            }
            guard let v = value(b) else { continue }
            pads = 0
            quad.append(v)
            if quad.count == 4 { flush() }
        }
        if quad.count == 1 { return nil }
        flush()
        return out
    }
}

// MARK: - RFC 2047 (email.header.decode_header + make_header)

public enum HeaderDecoding {
    static let encodedWord = Rx("=\\?([^?]*?)\\?([qQbB])\\?(.*?)\\?=")

    /// Charset names as `email.charset.Charset` normalises them, so chunk
    /// charsets can be compared (None counts as us-ascii).
    static func normalisedCharset(_ name: String?) -> String {
        guard let name else { return "us-ascii" }
        let lower = name.lowercased()
        let aliases: [String: String] = [
            "latin_1": "iso-8859-1", "latin-1": "iso-8859-1", "latin_2": "iso-8859-2", "latin-2": "iso-8859-2",
            "latin_9": "iso-8859-15", "latin-9": "iso-8859-15", "ascii": "us-ascii", "euc_jp": "euc-jp",
            "euc_kr": "euc-kr", "cp949": "ks_c_5601-1987",
        ]
        return aliases[lower] ?? lower
    }

    /// `decode_mime` in emailutil: `str(make_header(decode_header(raw))).strip()`,
    /// falling back to `raw.strip()` on any error.
    public static func decodeMime(_ raw: HeaderValue?) -> String {
        guard let raw, !raw.text.isEmpty else { return "" }
        if raw.eightBit { return raw.text.pyStrip }
        return (try? decode(raw.text))?.pyStrip ?? raw.text.pyStrip
    }

    /// For strings that are not header values (names from address parsing).
    public static func decodeMime(_ text: String) -> String {
        decodeMime(HeaderValue(text: text, eightBit: false))
    }

    struct DecodeError: Error {}

    /// The `(bytes, charset)` chunks of `decode_header`, then `Header.__str__`.
    static func decode(_ header: String) throws -> String {
        guard encodedWord.matches(header) else { return header }

        // (text, encoding, charset) triples; encoding nil for plain text.
        var words: [(text: String, encoding: String?, charset: String?)] = []
        for line in header.pySplitLines {
            var parts = encodedWord.split(line)
            var first = true
            while !parts.isEmpty {
                var unencoded = parts.removeFirst()
                if first {
                    unencoded = unencoded.pyLStrip
                    first = false
                }
                if !unencoded.isEmpty { words.append((unencoded, nil, nil)) }
                if parts.count >= 3 {
                    let charset = parts.removeFirst().lowercased()
                    let encoding = parts.removeFirst().lowercased()
                    let encoded = parts.removeFirst()
                    words.append((encoded, encoding, charset))
                }
            }
        }
        // Drop whitespace between two encoded words.
        var drop = Set<Int>()
        for n in words.indices where n > 1 {
            if words[n].encoding != nil && words[n - 2].encoding != nil && words[n - 1].text.pyIsSpace {
                drop.insert(n - 1)
            }
        }
        words = words.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }

        // Decode each word to bytes, collapsing runs of the same charset.
        var collapsed: [(bytes: [UInt8], charset: String?)] = []
        for word in words {
            let bytes: [UInt8]
            if word.encoding == nil {
                bytes = MIMEParams.rawUnicodeEscape(word.text)
            } else if word.encoding == "q" {
                bytes = qDecode(word.text)
            } else {
                var text = Array(word.text.utf8)
                let pad = text.count % 4
                if pad != 0 { text.append(contentsOf: Array("===".utf8).prefix(4 - pad)) }
                guard let decoded = TransferEncoding.decodeBase64(text) else { throw DecodeError() }
                bytes = decoded
            }
            if let lastIndex = collapsed.indices.last, collapsed[lastIndex].charset == word.charset {
                if word.charset == nil {
                    collapsed[lastIndex].bytes += [0x20] + bytes
                } else {
                    collapsed[lastIndex].bytes += bytes
                }
            } else {
                collapsed.append((bytes, word.charset))
            }
        }

        // make_header: decode each chunk (strictly), then Header._normalize.
        var chunks: [(text: String, charset: String)] = []
        for chunk in collapsed {
            let name = chunk.charset ?? "us-ascii"
            guard name.unicodeScalars.allSatisfy(\.isASCII) else { throw DecodeError() }
            let codec = normalisedCharset(chunk.charset)
            guard let text = Charsets.decode(chunk.bytes, charset: codec, strict: true) else { throw DecodeError() }
            chunks.append((text, codec))
        }
        var normalised: [(text: String, charset: String)] = []
        for chunk in chunks {
            if let lastIndex = normalised.indices.last, normalised[lastIndex].charset == chunk.charset {
                normalised[lastIndex].text += " " + chunk.text
            } else {
                normalised.append(chunk)
            }
        }

        // Header.__str__: keep a space at encoded/plain boundaries.
        func nonctext(_ s: Unicode.Scalar) -> Bool { PyText.isSpace(s) || s == "(" || s == ")" || s == "\\" }
        var out = ""
        var lastcs: String?
        var lastspace = false
        var started = false
        for chunk in normalised {
            var nextcs: String? = chunk.charset
            let firstScalar = chunk.text.unicodeScalars.first
            if started {
                let hasspace = firstScalar.map(nonctext) ?? false
                let lastPlain = lastcs == nil || lastcs == "us-ascii"
                let nextPlain = nextcs == nil || nextcs == "us-ascii"
                if !lastPlain {
                    if nextPlain && !hasspace {
                        out += " "
                        nextcs = nil
                    }
                } else if !nextPlain && !lastspace {
                    out += " "
                }
            }
            lastspace = chunk.text.unicodeScalars.last.map(nonctext) ?? false
            lastcs = nextcs
            out += chunk.text
            started = true
        }
        return out
    }

    /// `email.quoprimime.header_decode`.
    static func qDecode(_ s: String) -> [UInt8] {
        let bytes = MIMEParams.rawUnicodeEscape(s.replacingOccurrences(of: "_", with: " "))
        var out: [UInt8] = []
        var i = 0
        func hexval(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        while i < bytes.count {
            if bytes[i] == 0x3D, i + 2 < bytes.count,
               let hi = hexval(bytes[i + 1]), let lo = hexval(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }
}
