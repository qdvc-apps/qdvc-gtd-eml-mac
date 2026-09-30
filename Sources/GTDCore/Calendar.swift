import Foundation

/// Something that happened to an email on a given day, for the Calendar.
public enum CalendarEventKind: String, CaseIterable, Hashable, Comparable {
    case received, quoted, triaged, actionable, delegated, reference, archived

    public var label: String {
        switch self {
        case .received: return "Received"
        case .quoted: return "Quoted message"
        case .triaged: return "Triaged"
        case .actionable: return "Made actionable"
        case .delegated: return "Delegated"
        case .reference: return "Filed as reference"
        case .archived: return "Archived"
        }
    }

    /// The metadata stamp behind a kind (nil for header dates).
    public var stampField: String? {
        switch self {
        case .received, .quoted: return nil
        case .triaged: return "ds_triage"
        case .actionable: return "ds_actionable"
        case .delegated: return "ds_delegated"
        case .reference: return "ds_reference"
        case .archived: return "ds_archive"
        }
    }

    public static func < (a: CalendarEventKind, b: CalendarEventKind) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Which emails had which events on each day.
///
/// Events are the five ds_* stamps in metadata.csv (calendar days, used as
/// written), each email's own `Date:` header, and the dates of the earlier
/// messages quoted in its body. `due_date` is a deadline, not an event, and
/// is not included. An email without a usable `Date:` header contributes no
/// "received" event (the tool's fallback of "now" is not a real date), and a
/// quoted date that does not name a real day is skipped.
public struct CalendarIndex: Hashable {
    /// day → record id → the kinds of event it had that day (sorted).
    public let days: [Day: [String: [CalendarEventKind]]]

    public init(days: [Day: [String: [CalendarEventKind]]]) {
        self.days = days
    }

    /// Build the index. `instantDay` places a `Date:` header's instant on a
    /// day (in the zone the reader chose); `quotedDay` does the same for a
    /// quoted header's date parts, returning nil when they name no real day.
    public static func build(_ records: [EmailRecord], instantDay: (Date) -> Day,
                             quotedDay: (DateParts) -> Day?) -> CalendarIndex {
        var sets: [Day: [String: Set<CalendarEventKind>]] = [:]
        func add(_ day: Day, _ id: String, _ kind: CalendarEventKind) {
            sets[day, default: [:]][id, default: []].insert(kind)
        }
        for r in records {
            if let date = r.parsed.date { add(instantDay(date.date), r.id, .received) }
            for message in r.parsed.thread where message.depth > 0 {
                if let parts = message.dateParts, let day = quotedDay(parts) { add(day, r.id, .quoted) }
            }
            for kind in CalendarEventKind.allCases {
                guard let field = kind.stampField, let day = Analytics.parseDS(r.row[field]) else { continue }
                add(day, r.id, kind)
            }
        }
        var days: [Day: [String: [CalendarEventKind]]] = [:]
        for (day, byRecord) in sets {
            var entry: [String: [CalendarEventKind]] = [:]
            for (id, kinds) in byRecord { entry[id] = kinds.sorted() }
            days[day] = entry
        }
        return CalendarIndex(days: days)
    }

    /// Number of distinct emails with at least one event on `day`.
    public func count(on day: Day) -> Int { days[day]?.count ?? 0 }

    public func kinds(on day: Day, for id: String) -> [CalendarEventKind] { days[day]?[id] ?? [] }

    /// The days of the month containing `month`, in order.
    public static func monthDays(_ month: Day) -> [Day] {
        (1...Day.daysIn(year: month.year, month: month.month)).map { Day(year: month.year, month: month.month, day: $0) }
    }

    /// The first day of the month before or after `month`.
    public static func shift(_ month: Day, by months: Int) -> Day {
        let index = month.year * 12 + (month.month - 1) + months
        return Day(year: index / 12, month: index % 12 + 1, day: 1)
    }
}
