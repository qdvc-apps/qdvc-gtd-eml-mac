import Foundation

/// A port of `gtd_modules/emailutil.py`.
public enum EmailUtil {
    public static func subject(_ m: MIMEEntity) -> String {
        HeaderDecoding.decodeMime(m.get("Subject"))
    }

    /// The `Date:` header, or nil when it is missing or unparseable (the tool
    /// then uses the current time; see `ParsedEmail.effectiveDate`).
    public static func date(_ m: MIMEEntity) -> EmailDate? {
        DateParsing.parse(m.get("Date"))
    }

    public static func pairs(_ m: MIMEEntity, _ header: String) -> [AddressPair] {
        let values = m.getAll(header).map(\.text)
        return values.isEmpty ? [] : Addresses.getaddresses(values)
    }

    /// `format_addresses`: decoded, comma-joined.
    public static func formatAddresses(_ pairs: [AddressPair]) -> String {
        var parts: [String] = []
        for pair in pairs {
            let name = HeaderDecoding.decodeMime(pair.name)
            if !name.isEmpty && !pair.address.isEmpty {
                parts.append("\(name) <\(pair.address)>")
            } else if !pair.address.isEmpty {
                parts.append(pair.address)
            } else if !name.isEmpty {
                parts.append(name)
            }
        }
        return parts.joined(separator: ", ")
    }

    /// `get_email_correspondents`: From, To and Cc, de-duplicated, minus
    /// `exclude` (compared case-insensitively).
    public static func correspondents(_ pairs: [AddressPair], exclude: [String]) -> [String] {
        let excluded = Set(exclude.map { $0.lowercased() })
        var people: [String] = []
        for pair in pairs {
            if !pair.address.isEmpty && excluded.contains(pair.address.lowercased()) { continue }
            let name = HeaderDecoding.decodeMime(pair.name)
            let entry = (!name.isEmpty && !pair.address.isEmpty) ? "\(name) <\(pair.address)>"
                : (name.isEmpty ? pair.address : name)
            if !entry.isEmpty && !people.contains(entry) { people.append(entry) }
        }
        return people
    }

    /// `is_attachment`.
    static func isAttachment(_ part: MIMEEntity) -> Bool {
        if (part.get("Content-Disposition")?.text ?? "").lowercased().contains("attachment") { return true }
        if let name = part.filename, !name.isEmpty { return true }
        return false
    }

    /// `list_attachments`.
    public static func attachments(_ m: MIMEEntity) -> [String] {
        guard m.isMultipart else { return [] }
        var names: [String] = []
        for part in m.walk() where !part.isMultipart && isAttachment(part) {
            if let name = part.filename, !name.isEmpty {
                names.append(HeaderDecoding.decodeMime(name))
            } else {
                names.append("(unnamed attachment)")
            }
        }
        return names
    }

    /// `decode_part_text`.
    static func decodePartText(_ part: MIMEEntity) -> String {
        guard let payload = part.decodedPayload() else { return "" }
        let charset = part.contentCharset ?? "utf-8"
        return Charsets.decode(payload, charset: charset, strict: false)
            ?? String(decoding: payload, as: UTF8.self)
    }

    private static let scriptStyleRx = Rx("<(script|style).*?>.*?</\\1>", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let brRx = Rx("<br\\s*/?>", [.caseInsensitive])
    private static let pCloseRx = Rx("</p>", [.caseInsensitive])
    private static let tagRx = Rx("<[^>]+>")
    private static let blankRunRx = Rx("\\n{3,}")

    /// `strip_html`.
    public static func stripHTML(_ html: String) -> String {
        var text = scriptStyleRx.replace(html, with: "")
        text = brRx.replace(text, with: "\n")
        text = pCloseRx.replace(text, with: "\n\n")
        text = tagRx.replace(text, with: "")
        for (entity, ch) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                             ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: ch)
        }
        return blankRunRx.replace(text, with: "\n\n").pyStrip
    }

    /// `get_email_body_text`.
    public static func bodyText(_ m: MIMEEntity, renderHTML: Bool) -> String {
        if !m.isMultipart {
            let text = decodePartText(m)
            if renderHTML && m.contentType == "text/html" { return stripHTML(text) }
            return text
        }
        var plain: String?
        var html: String?
        for part in m.walk() where !part.isMultipart && !isAttachment(part) {
            let ctype = part.contentType
            if ctype == "text/plain" && plain == nil {
                plain = decodePartText(part)
            } else if ctype == "text/html" && html == nil {
                html = decodePartText(part)
            }
        }
        if let plain, !plain.pyStrip.isEmpty { return plain }
        if let html, !html.pyStrip.isEmpty { return renderHTML ? stripHTML(html) : html }
        return ""
    }

    static let messageRefRx = Rx("message\\s+ref\\.?\\s*[:\\-]?\\s*([A-Za-z0-9_-]{6,32})", [.caseInsensitive])

    /// `find_message_ref`: the first ref in the (raw) body.
    public static func findMessageRef(_ m: MIMEEntity) -> String? {
        let body = bodyText(m, renderHTML: false)
        guard !body.isEmpty else { return nil }
        return messageRefRx.firstMatch(body)?.group(1)
    }
}

/// Everything the app needs from one `.eml` file, parsed once. Metadata and
/// configuration are applied on top of this (see `EmailRecord`).
public struct ParsedEmail: Hashable {
    public var subject: String
    /// The `Date:` header; nil when missing or unparseable.
    public var date: EmailDate?
    public var fromText: String
    public var toText: String
    public var ccText: String
    public var bccText: String
    /// Address pairs per header, for account matching.
    public var fromPairs: [AddressPair]
    public var toPairs: [AddressPair]
    public var ccPairs: [AddressPair]
    public var bccPairs: [AddressPair]
    /// From + To + Cc parsed together, as `get_email_correspondents` does.
    public var correspondentPairs: [AddressPair]
    public var attachments: [String]
    /// The body as text (HTML converted), as the web UI shows it.
    public var body: String
    public var messageRef: String?
    public var thread: [ThreadMessage]
    public var preview: String
    /// Set when the file could not be read at all.
    public var error: String?

    public init(message m: MIMEEntity) {
        subject = EmailUtil.subject(m)
        date = EmailUtil.date(m)
        fromPairs = EmailUtil.pairs(m, "From")
        toPairs = EmailUtil.pairs(m, "To")
        ccPairs = EmailUtil.pairs(m, "Cc")
        bccPairs = EmailUtil.pairs(m, "Bcc")
        fromText = EmailUtil.formatAddresses(fromPairs)
        toText = EmailUtil.formatAddresses(toPairs)
        ccText = EmailUtil.formatAddresses(ccPairs)
        bccText = EmailUtil.formatAddresses(bccPairs)
        let raw = (m.getAll("From") + m.getAll("To") + m.getAll("Cc")).map(\.text)
        correspondentPairs = raw.isEmpty ? [] : Addresses.getaddresses(raw)
        attachments = EmailUtil.attachments(m)
        body = EmailUtil.bodyText(m, renderHTML: true)
        messageRef = EmailUtil.findMessageRef(m)
        thread = EmailThread.splitHistory(body)
        preview = EmailThread.summarise(body)
        error = nil
    }

    public init(data: Data) {
        self.init(message: MIMEParser.parse(data))
    }

    /// A placeholder for a file that could not be read.
    public init(unreadable filename: String, error: String) {
        subject = "(could not read \(filename))"
        date = nil
        fromText = ""; toText = ""; ccText = ""; bccText = ""
        fromPairs = []; toPairs = []; ccPairs = []; bccPairs = []; correspondentPairs = []
        attachments = []
        body = ""
        messageRef = nil
        thread = []
        preview = ""
        self.error = error
    }

    public static func load(_ url: URL) -> ParsedEmail {
        do {
            return ParsedEmail(data: try Data(contentsOf: url))
        } catch {
            return ParsedEmail(unreadable: url.lastPathComponent, error: error.localizedDescription)
        }
    }

    /// `get_email_date`: the header's date, else now (UTC).
    public func effectiveDate(now: Date = Date()) -> EmailDate {
        date ?? DateParsing.now(now)
    }

    /// `match_own_account`: prefer the account that received the mail.
    public func ownAccount(_ accounts: [OwnAccount]) -> OwnAccount? {
        guard !accounts.isEmpty else { return nil }
        for list in [toPairs, ccPairs, bccPairs, fromPairs] {
            for pair in list where !pair.address.isEmpty {
                if let account = accounts.first(where: { $0.emailAddress == pair.address.lowercased() }) {
                    return account
                }
            }
        }
        return nil
    }

    /// `match_own_accounts_by_role`: (recipient accounts, sender accounts).
    public func ownAccountsByRole(_ accounts: [OwnAccount]) -> (recipient: [OwnAccount], sender: [OwnAccount]) {
        func matches(_ lists: [[AddressPair]]) -> [OwnAccount] {
            var seen = Set<String>()
            var found: [OwnAccount] = []
            for list in lists {
                for pair in list {
                    let key = pair.address.lowercased()
                    if let account = accounts.first(where: { $0.emailAddress == key }), !seen.contains(key) {
                        seen.insert(key)
                        found.append(account)
                    }
                }
            }
            return found
        }
        guard !accounts.isEmpty else { return ([], []) }
        return (matches([toPairs, ccPairs, bccPairs]), matches([fromPairs]))
    }

    public func correspondents(excluding accounts: [OwnAccount]) -> [String] {
        EmailUtil.correspondents(correspondentPairs, exclude: accounts.map(\.emailAddress))
    }
}
