import Foundation

/// CSV compatible with Python's `csv` module in its default (excel) dialect:
/// comma delimiter, double-quote quoting with doubled quotes inside, minimal
/// quoting and "\r\n" line endings on write, and non-strict parsing on read.
public enum CSV {
    /// Parse text into records. Blank lines produce no record (Python's
    /// `csv.reader` yields `[]` for them, which `DictReader` skips).
    public static func parse(_ text: String) -> [[String]] {
        enum State { case startRecord, startField, inField, inQuoted, quoteInQuoted }
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var state = State.startRecord

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
        }
        func endRecord() {
            endField()
            rows.append(row)
            row = []
        }

        for c in text.unicodeScalars {
            let isEOL = c == "\n" || c == "\r"
            switch state {
            case .startRecord:
                if isEOL { continue }
                state = .startField
                fallthrough
            case .startField:
                if isEOL {
                    endRecord()
                    state = .startRecord
                } else if c == "\"" {
                    state = .inQuoted
                } else if c == "," {
                    endField()
                } else {
                    field.append(c)
                    state = .inField
                }
            case .inField:
                if isEOL {
                    endRecord()
                    state = .startRecord
                } else if c == "," {
                    endField()
                    state = .startField
                } else {
                    field.append(c)
                }
            case .inQuoted:
                if c == "\"" {
                    state = .quoteInQuoted
                } else {
                    field.append(c)  // newlines inside quotes are kept as-is
                }
            case .quoteInQuoted:
                if c == "\"" {
                    field.append(c)
                    state = .inQuoted
                } else if c == "," {
                    endField()
                    state = .startField
                } else if isEOL {
                    endRecord()
                    state = .startRecord
                } else {
                    // Non-strict: text after a closing quote joins the field.
                    field.append(c)
                    state = .inField
                }
            }
        }
        // End of data: a trailing record without a line ending (or an
        // unterminated quoted field, which non-strict Python also returns).
        if state != .startRecord {
            endRecord()
        }
        return rows
    }

    /// Records as dictionaries keyed by the header row, like Python's
    /// `csv.DictReader`: missing trailing values are absent from the
    /// dictionary, and a later duplicate column name wins. A UTF-8 byte-order
    /// mark before the header is ignored (Python would keep it and then fail
    /// to find the first column).
    public static func parseWithHeader(_ text: String) -> [[String: String]] {
        var body = text
        if body.unicodeScalars.first == "\u{FEFF}" { body.unicodeScalars.removeFirst() }
        let rows = parse(body)
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { values in
            var dict: [String: String] = [:]
            for (key, value) in zip(header, values) { dict[key] = value }
            return dict
        }
    }

    /// Format records as Python's `csv.writer` would.
    public static func format(_ rows: [[String]]) -> String {
        var out = ""
        for row in rows {
            if row.count == 1, row[0].isEmpty {
                out += "\"\""  // Python quotes a lone empty field
            } else {
                out += row.map(quote).joined(separator: ",")
            }
            out += "\r\n"
        }
        return out
    }

    private static func quote(_ value: String) -> String {
        let needsQuotes = value.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
