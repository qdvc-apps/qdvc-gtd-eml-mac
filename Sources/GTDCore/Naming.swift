import Foundation

/// A port of `gtd_modules/naming.py`: the
/// `yyyy-mm-dd-brief-description[-ref-<nanoid>].eml` convention.
public enum Naming {
    static let nonAlnumRx = Rx("[^a-z0-9]+")
    static let dashRunRx = Rx("-{2,}")

    /// `slugify`: lower-case, `[a-z0-9-]` only.
    public static func slugify(_ text: String) -> String {
        var s = text.lowercased()
        s = nonAlnumRx.replace(s, with: "-")
        s = dashRunRx.replace(s, with: "-")
        return s.pyStrip(["-"])
    }

    /// `build_base_filename`: the base name (no extension), truncated so that
    /// base + ".eml" fits in `maxChars`, never truncating the ref suffix.
    public static func buildBaseFilename(day: Day, subject: String, maxChars: Int, messageRef: String?) -> String {
        let dateStr = day.iso
        var slug = slugify(subject)
        if slug.isEmpty { slug = "no-subject" }
        let refSuffix = (messageRef?.isEmpty ?? true) ? "" : "-ref-\(messageRef!)"
        let maxBase = maxChars - 4
        let available = maxBase - dateStr.pyCount - 1 - refSuffix.pyCount
        if available < 0 {
            let base = dateStr + refSuffix
            return base.pyPrefix(maxBase).pyRStrip(["-"])
        }
        if slug.pyCount > available {
            slug = slug.pyPrefix(available).pyRStrip(["-"])
        }
        let base = slug.isEmpty ? dateStr + refSuffix : "\(dateStr)-\(slug)\(refSuffix)"
        return base.pyStrip(["-"])
    }

    /// `unique_filename`: `<base>.eml`, or with a `-N` counter (before any
    /// protected ref suffix) when that name is taken.
    public static func uniqueFilename(base: String, existing: Set<String>, maxChars: Int, messageRef: String?) -> String {
        let candidate = base + ".eml"
        if !existing.contains(candidate) { return candidate }
        var refSuffix = (messageRef?.isEmpty ?? true) ? "" : "-ref-\(messageRef!)"
        let head: String
        if !refSuffix.isEmpty && base.hasSuffix(refSuffix) {
            head = base.pyPrefix(base.pyCount - refSuffix.pyCount)
        } else {
            refSuffix = ""
            head = base
        }
        var n = 2
        while true {
            let suffix = "-\(n)"
            let maxHead = maxChars - 4 - suffix.pyCount - refSuffix.pyCount
            let trimmed = head.pyCount > maxHead ? pySlicePrefix(head, maxHead).pyRStrip(["-"]) : head
            let name = "\(trimmed)\(suffix)\(refSuffix).eml"
            if !existing.contains(name) { return name }
            n += 1
        }
    }

    /// Python's `s[:n]` where n may be negative.
    static func pySlicePrefix(_ s: String, _ n: Int) -> String { s.pyPrefix(n) }
}
