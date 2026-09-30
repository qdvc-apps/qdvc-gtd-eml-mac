import SwiftUI
import GTDCore

/// Overview → Calendar: a month at a time, each day shaded by how many
/// emails had something happen that day (received, quoted, or a workflow
/// stamp). Days with no events are blank. Clicking a day lists its emails.
struct CalendarView: View {
    @Environment(AppModel.self) private var model

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        let month = model.calendarMonth
        let days = CalendarIndex.monthDays(month)
        let counts = days.map { model.calendarIndex.count(on: $0) }
        let busiest = counts.max() ?? 0
        let today = model.dates.today
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Calendar").font(.largeTitle.weight(.semibold))
                    Spacer()
                    Button {
                        model.calendarMonth = CalendarIndex.shift(month, by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Previous month")
                    Text("\(DateFormatting.monthName(month.month)) \(String(month.year))")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 190)
                    Button {
                        model.calendarMonth = CalendarIndex.shift(month, by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Next month")
                    Button("Today") {
                        model.calendarMonth = Day(year: today.year, month: today.month, day: 1)
                    }
                    .disabled(month.year == today.year && month.month == today.month)
                }

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Self.weekdays, id: \.self) { name in
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    // Blank cells before the 1st (weeks start on Monday).
                    ForEach(0..<month.weekday, id: \.self) { i in
                        Color.clear.frame(height: 64).id("lead-\(i)")
                    }
                    ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                        DayCell(day: day, count: counts[i], busiest: busiest, isToday: day == today) {
                            model.openCalendarDay(day)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text("Fewer").font(.caption).foregroundStyle(.secondary)
                    ForEach([0.2, 0.4, 0.6, 0.8, 1.0], id: \.self) { level in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(DayCell.opacity(for: level)))
                            .frame(width: 14, height: 14)
                    }
                    Text("More").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(summary(counts: counts, days: days))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                MonthBreakdown(days: days)

                Text("Counts distinct emails per day with any event: the email's Date header, the dates of messages quoted in it, and the ds_* stamps in metadata.csv. Header dates use the time zone chosen in Settings; stamps are used as written. Due dates are not events.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(counts: [Int], days: [Day]) -> String {
        let active = counts.filter { $0 > 0 }.count
        var emails = Set<String>()
        for day in days { emails.formUnion((model.calendarIndex.days[day] ?? [:]).keys) }
        guard active > 0 else { return "No events this month" }
        return "\(emails.count) email\(emails.count == 1 ? "" : "s") on \(active) day\(active == 1 ? "" : "s")"
    }
}

/// One day of the month grid.
private struct DayCell: View {
    let day: Day
    let count: Int
    let busiest: Int
    let isToday: Bool
    let open: () -> Void

    /// Shading for a share of the busiest day (never too faint to see).
    static func opacity(for share: Double) -> Double { 0.15 + 0.75 * share }

    var body: some View {
        let shade = count > 0 && busiest > 0 ? DayCell.opacity(for: Double(count) / Double(busiest)) : 0
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(day.day)")
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .monospacedDigit()
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .topLeading)
            .foregroundStyle(shade > 0.6 ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(shade)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isToday ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isToday ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help(count == 0 ? "" : "\(count) email\(count == 1 ? "" : "s") \u{2014} click to list them")
    }
}

/// How many emails had each kind of event this month.
private struct MonthBreakdown: View {
    @Environment(AppModel.self) private var model
    let days: [Day]

    var body: some View {
        let totals = CalendarEventKind.allCases.map { kind -> (CalendarEventKind, Int) in
            var ids = Set<String>()
            for day in days {
                for (id, kinds) in model.calendarIndex.days[day] ?? [:] where kinds.contains(kind) { ids.insert(id) }
            }
            return (kind, ids.count)
        }.filter { $0.1 > 0 }
        if !totals.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("This month").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    ForEach(totals, id: \.0) { kind, n in
                        GridRow {
                            Text(kind.label)
                            Text("\(n)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }
}
