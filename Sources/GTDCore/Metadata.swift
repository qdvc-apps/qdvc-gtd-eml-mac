import Foundation

/// A port of `gtd_modules/metadata.py`. `metadata.csv` sits at the workspace
/// root with one row per `.eml` file across all six folders; it is written
/// exactly as Python's `csv.DictWriter` writes it (excel dialect, "\r\n",
/// minimal quoting, rows sorted by filename in code-point order), so the CLI
/// and this app produce identical bytes.
public enum Metadata {
    public static let fileName = "metadata.csv"

    public static let headers = [
        "eml_filename", "general_notes", "project", "next_action", "due_date", "message_ref", "flags",
        "ds_triage", "ds_actionable", "ds_delegated", "ds_reference", "ds_archive",
    ]
    /// Every column except the key.
    public static let readable = Array(headers.dropFirst())
    /// What `gtd metadata set` (and the Edit Annotations sheet) may change.
    public static let editable = ["general_notes", "project", "next_action", "due_date", "flags"]
    public static let stampFields = ["ds_triage", "ds_actionable", "ds_delegated", "ds_reference", "ds_archive"]
    public static let writable = editable + stampFields

    public typealias Row = [String: String]

    static func url(_ root: URL) -> URL { root.appendingPathComponent(fileName) }

    public static func blankRow() -> Row {
        var row: Row = [:]
        for h in readable { row[h] = "" }
        return row
    }

    /// `load_metadata`: rows keyed by filename (a later duplicate wins).
    public static func load(root: URL) -> [String: Row] {
        guard let text = readTextFile(url(root)) else { return [:] }
        return parse(text)
    }

    public static func parse(_ text: String) -> [String: Row] {
        var rows: [String: Row] = [:]
        for record in CSV.parseWithHeader(text) {
            let key = record["eml_filename"] ?? ""
            guard !key.isEmpty else { continue }
            var row: Row = [:]
            for h in readable { row[h] = record[h] ?? "" }
            rows[key] = row
        }
        return rows
    }

    /// The CSV text for `rows`, sorted as Python's `sorted()` sorts.
    public static func render(_ rows: [String: Row]) -> String {
        var records: [[String]] = [headers]
        for name in rows.keys.sorted(by: codePointPrecedes) {
            let row = rows[name] ?? [:]
            records.append([name] + readable.map { row[$0] ?? "" })
        }
        return CSV.format(records)
    }

    /// `sync_metadata`'s row set: one row per current file, keeping existing
    /// values, seeding new rows from `seeds`, dropping vanished files.
    public static func synced(_ existing: [String: Row], current: Set<String>, seeds: [String: Row] = [:]) -> [String: Row] {
        var rows: [String: Row] = [:]
        for name in current {
            if let prev = existing[name] {
                rows[name] = prev
            } else {
                var row = blankRow()
                for (k, v) in seeds[name] ?? [:] { row[k] = v }
                rows[name] = row
            }
        }
        return rows
    }

    static func write(_ rows: [String: Row], root: URL) throws {
        try writeTextAtomically(render(rows), to: url(root))
    }
}
