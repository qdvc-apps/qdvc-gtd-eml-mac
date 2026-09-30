import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Decoding bytes by charset name, as Python's `bytes.decode(name, errors)`
/// does for the charsets mail actually uses. The common ones (UTF-8, ASCII,
/// Latin-1, Windows-1252, UTF-16) are decoded here so that `errors="replace"`
/// behaves exactly like Python; everything else goes through Foundation (and,
/// on macOS, the IANA name table), which covers the CJK and Cyrillic
/// charsets. Returns nil when Python would raise `LookupError` (an unknown
/// charset) or, in strict mode, `UnicodeDecodeError`.
enum Charsets {
    enum Kind {
        case utf8, ascii, latin1, cp1252, utf16, utf16be, utf16le
        case foundation(String.Encoding)
    }

    /// Python's codec-name normalisation, reduced to what matters here:
    /// case-insensitive, punctuation-insensitive.
    static func key(_ name: String) -> String {
        String(String.UnicodeScalarView(name.lowercased().unicodeScalars.filter(PyText.isASCIIAlnum)))
    }

    static func kind(for name: String) -> Kind? {
        let k = key(name)
        switch k {
        case "utf8", "utf", "u8", "cp65001", "utf8sig": return .utf8
        case "ascii", "usascii", "us", "646", "ansix341968", "ansix341986", "cp367", "ibm367",
             "iso646us", "isoir6", "csascii":
            return .ascii
        case "latin1", "latin", "l1", "iso88591", "iso885911987", "8859", "cp819", "ibm819", "isoir100",
             "csisolatin1":
            return .latin1
        case "cp1252", "windows1252", "1252": return .cp1252
        case "utf16": return .utf16
        case "utf16be", "unicodebigunmarked": return .utf16be
        case "utf16le", "unicodelittleunmarked": return .utf16le
        case "iso88592", "latin2", "l2": return .foundation(.isoLatin2)
        case "cp1250", "windows1250": return .foundation(.windowsCP1250)
        case "cp1251", "windows1251": return .foundation(.windowsCP1251)
        case "cp1253", "windows1253": return .foundation(.windowsCP1253)
        case "cp1254", "windows1254": return .foundation(.windowsCP1254)
        case "shiftjis", "sjis", "cp932", "ms932", "mskanji", "csshiftjis": return .foundation(.shiftJIS)
        case "eucjp", "ujis": return .foundation(.japaneseEUC)
        case "iso2022jp", "csiso2022jp": return .foundation(.iso2022JP)
        case "macroman", "macintosh": return .foundation(.macOSRoman)
        case "utf32": return .foundation(.utf32)
        case "utf32be": return .foundation(.utf32BigEndian)
        case "utf32le": return .foundation(.utf32LittleEndian)
        default:
            #if canImport(Darwin)
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            let invalid: CFStringEncoding = 0xFFFF_FFFF
            if cf != invalid {
                return .foundation(String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)))
            }
            #endif
            return nil
        }
    }

    /// True when Python would recognise the charset name.
    static func isKnown(_ name: String) -> Bool { kind(for: name) != nil }

    /// Decode `bytes`; nil on unknown charset, or on invalid data when `strict`.
    static func decode(_ bytes: [UInt8], charset: String, strict: Bool) -> String? {
        guard let kind = kind(for: charset) else { return nil }
        switch kind {
        case .utf8:
            if strict {
                return String(bytes: bytes, encoding: .utf8)
            }
            return String(decoding: bytes, as: UTF8.self)
        case .ascii:
            var out = String.UnicodeScalarView()
            for b in bytes {
                if b < 0x80 {
                    out.append(Unicode.Scalar(b))
                } else {
                    if strict { return nil }
                    out.append("\u{FFFD}")
                }
            }
            return String(out)
        case .latin1:
            return latin1(bytes)
        case .cp1252:
            var out = String.UnicodeScalarView()
            for b in bytes {
                if let s = cp1252Scalar(b) {
                    out.append(s)
                } else {
                    if strict { return nil }
                    out.append("\u{FFFD}")
                }
            }
            return String(out)
        case .utf16, .utf16be, .utf16le:
            var data = bytes
            var bigEndian = false
            if case .utf16be = kind { bigEndian = true }
            if case .utf16 = kind {
                // Python's "utf-16": honour a BOM, else little-endian.
                if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
                    bigEndian = true
                    data.removeFirst(2)
                } else if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
                    data.removeFirst(2)
                }
            }
            if data.count % 2 == 1 {
                if strict { return nil }
                data.removeLast()
            }
            var units: [UInt16] = []
            units.reserveCapacity(data.count / 2)
            var i = 0
            while i + 1 < data.count {
                units.append(bigEndian ? UInt16(data[i]) << 8 | UInt16(data[i + 1])
                                       : UInt16(data[i + 1]) << 8 | UInt16(data[i]))
                i += 2
            }
            if strict {
                var scalars = String.UnicodeScalarView()
                let hadError = transcode(units.makeIterator(), from: UTF16.self, to: UTF32.self,
                                         stoppingOnError: true) { unit in
                    if let scalar = Unicode.Scalar(unit) { scalars.append(scalar) }
                }
                return hadError ? nil : String(scalars)
            }
            return String(decoding: units, as: UTF16.self)
        case .foundation(let encoding):
            if let s = String(data: Data(bytes), encoding: encoding) { return s }
            if strict { return nil }
            // Foundation cannot replace invalid sequences; fall back to
            // lenient UTF-8, which keeps any ASCII text readable.
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static func latin1(_ bytes: [UInt8]) -> String {
        var out = String.UnicodeScalarView()
        for b in bytes { out.append(Unicode.Scalar(b)) }
        return String(out)
    }

    /// Windows-1252 as Python's `cp1252` codec defines it (five bytes are
    /// undefined and fail to decode).
    static func cp1252Scalar(_ b: UInt8) -> Unicode.Scalar? {
        if b < 0x80 || b >= 0xA0 { return Unicode.Scalar(b) }
        let table: [UInt32] = [
            0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
            0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
            0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
            0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
        ]
        let v = table[Int(b) - 0x80]
        return v == 0 ? nil : Unicode.Scalar(v)
    }
}
