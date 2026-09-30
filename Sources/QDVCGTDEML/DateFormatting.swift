import Foundation
import GTDCore

/// The single place that turns a date into text, following the web UI's
/// rules (assets/dates.js):
///   * a `Date:` header is an absolute instant, shown in the chosen zone;
///   * a quoted in-text header date is wall-clock numbers, shown as written
///     unless the reader asks to treat zone-less times as UTC (a stated
///     offset always wins);
///   * a ds_* stamp or due date is a calendar day, reformatted, never shifted.
struct DateFormatting {
    var style: DateStyle
    var zone: TimeZone
    var naive: NaiveDates

    static let englishMonths = ["January", "February", "March", "April", "May", "June", "July", "August",
                                "September", "October", "November", "December"]
    static let englishWeekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    struct Fields {
        var y: Int, mo: Int, d: Int
        var h: Int = 0, mi: Int = 0
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    func fields(_ date: Date) -> Fields {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return Fields(y: c.year ?? 1970, mo: c.month ?? 1, d: c.day ?? 1, h: c.hour ?? 0, mi: c.minute ?? 0)
    }

    /// The calendar day an instant falls on in the chosen zone.
    func day(_ date: Date) -> Day {
        let f = fields(date)
        return Day(year: f.y, month: f.mo, day: f.d)
    }

    var today: Day { day(Date()) }

    func render(_ f: Fields, withTime: Bool, style: DateStyle? = nil) -> String {
        let time = withTime ? String(format: " %02d:%02d", f.h, f.mi) : ""
        switch style ?? self.style {
        case .iso:
            return String(format: "%04d-%02d-%02d", f.y, f.mo, f.d) + time
        case .medium:
            return "\(f.d) \(DateFormatting.englishMonths[f.mo - 1].prefix(3)) \(f.y)" + time
        case .long:
            let weekday = Day(year: f.y, month: f.mo, day: f.d).weekday
            return "\(DateFormatting.englishWeekdays[weekday]), \(f.d) \(DateFormatting.englishMonths[f.mo - 1]) \(f.y)" + time
        }
    }

    /// An email's own date, in full.
    func full(_ date: Date) -> String { render(fields(date), withTime: true) }

    /// The compact form (medium or ISO, keeping the chosen family).
    func compact(_ date: Date, withTime: Bool = true) -> String {
        render(fields(date), withTime: withTime, style: style == .iso ? .iso : .medium)
    }

    /// The message list's date column, Mail-style: the time today,
    /// "Yesterday", the weekday within the last week, else a compact date.
    func list(_ date: Date) -> String {
        let f = fields(date)
        let d = Day(year: f.y, month: f.mo, day: f.d)
        let t = today
        if d == t { return String(format: "%02d:%02d", f.h, f.mi) }
        if d == t.adding(days: -1) { return "Yesterday" }
        if d < t && d > t.adding(days: -7) { return DateFormatting.englishWeekdays[d.weekday] }
        return render(f, withTime: false, style: style == .iso ? .iso : .medium)
    }

    /// A metadata day (ds_* stamp or due date); free text passes through.
    func isoDay(_ value: String) -> String {
        guard let d = Day(iso: value.trimmingCharacters(in: .whitespaces)) else { return value }
        return render(Fields(y: d.year, mo: d.month, d: d.day), withTime: false)
    }

    /// A quoted header's date, from the parts `parse_date_text` recovered.
    func quoted(_ parts: DateParts?, raw: String) -> String {
        guard let p = parts else { return raw }
        let withTime = p.h != nil
        var f = Fields(y: p.y, mo: p.mo, d: p.d, h: p.h ?? 0, mi: p.mi ?? 0)
        guard Day(validYear: p.y, month: p.mo, day: p.d) != nil else { return raw }
        let offsetMinutes: Int?
        if let o = p.offset {
            offsetMinutes = o
        } else if naive == .utc && withTime {
            offsetMinutes = 0
        } else {
            return render(f, withTime: withTime)
        }
        guard withTime, let offsetMinutes else { return render(f, withTime: withTime) }
        // Numbers written at `offset`: convert that instant into the zone.
        let dayNumber = Day(year: p.y, month: p.mo, day: p.d).days(since: Day(year: 1970, month: 1, day: 1))
        let epoch = dayNumber * 86400 + f.h * 3600 + f.mi * 60 - offsetMinutes * 60
        f = fields(Date(timeIntervalSince1970: TimeInterval(epoch)))
        return render(f, withTime: true)
    }

    /// Month names for the list's date headings.
    static func monthName(_ month: Int) -> String { englishMonths[max(1, min(12, month)) - 1] }
}
