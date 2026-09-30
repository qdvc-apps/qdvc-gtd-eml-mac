import Charts
import SwiftUI
import GTDCore

/// Overview → Performance: the open backlog and throughput sections of the
/// CLI's performance dashboard. Like `generate_dashboard`, it shows figures
/// only once 01-input is empty and the date stamps are consistent.
struct PerformanceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Performance").font(.largeTitle.weight(.semibold))
                    Spacer()
                    if !model.config.myOwnAccounts.isEmpty {
                        Picker("Account", selection: $model.performanceAccount) {
                            Text("All accounts").tag(String?.none)
                            ForEach(model.config.myOwnAccounts) { a in
                                Text(a.displayName).tag(String?.some(a.emailAddress))
                            }
                        }
                        .fixedSize()
                    }
                }
                if !model.autofix.isClean {
                    NotReadyView()
                } else {
                    let computed = model.performanceMetrics
                    BacklogSection(stats: Analytics.backlogStats(computed, today: model.today),
                                   histogram: Analytics.backlogHistogram(computed, today: model.today))
                    ThroughputSection(computed: computed)
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NotReadyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let plan = model.autofix
        VStack(alignment: .leading, spacing: 10) {
            Label("Performance figures need a complete, consistent workflow history.",
                  systemImage: "chart.line.downtrend.xyaxis")
                .font(.headline)
            if plan.pendingInput > 0 {
                Text("\(plan.pendingInput) file\(plan.pendingInput == 1 ? " is" : "s are") still in 01-input. Ingest them first.")
                Button("Ingest") { model.ingest() }
            } else {
                Text(plan.blockers.isEmpty
                     ? "\(plan.fixes.count) date stamp\(plan.fixes.count == 1 ? " is" : "s are") missing or inconsistent."
                     : "\(plan.blockers.count) email\(plan.blockers.count == 1 ? " needs" : "s need") manual attention.")
                Button("Review Date Stamps\u{2026}") { model.beginReviewDateStamps() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.1)))
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    var sub: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
            if !sub.isEmpty {
                Text(sub).font(.caption).foregroundStyle(.tertiary).lineLimit(2).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
    }
}

private struct BacklogSection: View {
    let stats: BacklogStats
    let histogram: [Int]

    private func days(_ v: Double?) -> String { v.map { String(format: "%.1f days", $0) } ?? "\u{2013}" }
    private func days(_ v: Int?) -> String { v.map { "\($0) days" } ?? "\u{2013}" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Backlog").font(.title3.weight(.semibold))
            if stats.count == 0 {
                Text("No ongoing emails \u{2014} the backlog is empty.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    StatCard(value: "\(stats.count)", label: "open now")
                    StatCard(value: days(stats.medianAge), label: "median age")
                    StatCard(value: days(stats.meanAge), label: "mean age")
                    StatCard(value: "\(stats.staleCount)", label: "older than \(stats.staleThreshold) days")
                    StatCard(value: days(stats.oldestAge), label: "oldest open", sub: stats.oldestFilename ?? "")
                    StatCard(value: days(stats.longestStallDays), label: "longest stall",
                             sub: stats.longestStallFilename.map { "in \(stats.longestStallStage ?? ""): \($0)" } ?? "")
                }
                Text("Current pile by age (days)").font(.headline).padding(.top, 6)
                Chart {
                    ForEach(Array(zip(Analytics.histogramLabels, histogram)), id: \.0) { label, count in
                        BarMark(x: .value("Age", label), y: .value("Emails", count))
                            .foregroundStyle(Color.accentColor.gradient)
                            .annotation(position: .top) {
                                if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
                            }
                    }
                }
                .chartYAxisLabel("Emails")
                .frame(height: 200)
            }
        }
    }
}

private struct ThroughputSection: View {
    @Environment(AppModel.self) private var model
    let computed: [EmailMetrics]

    private struct Point: Identifiable {
        let date: Date
        let series: String
        let value: Int
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    private func date(_ d: Day) -> Date {
        var c = DateComponents()
        c.year = d.year
        c.month = d.month
        c.day = d.day
        c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }

    var body: some View {
        @Bindable var model = model
        let flow = Analytics.flowSeries(computed, period: model.performancePeriod)
        let unit: Calendar.Component = model.performancePeriod == .weekly ? .weekOfYear : .month
        let bars = flow.periods.indices.flatMap { i in
            [Point(date: date(flow.periods[i]), series: "Arrived", value: flow.arrivals[i]),
             Point(date: date(flow.periods[i]), series: "Resolved", value: flow.resolutions[i])]
        }
        let backlog = flow.periods.indices.map { i in
            Point(date: date(flow.periods[i]), series: "Open backlog", value: flow.backlog[i])
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Throughput").font(.title3.weight(.semibold))
                Spacer()
                Picker("Period", selection: $model.performancePeriod) {
                    Text("Weekly").tag(FlowPeriod.weekly)
                    Text("Monthly").tag(FlowPeriod.monthly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if flow.periods.isEmpty {
                Text("No activity yet.").foregroundStyle(.secondary)
            } else {
                Text("Arrivals and resolutions per \(model.performancePeriod == .weekly ? "week" : "month")")
                    .font(.headline)
                Chart(bars) { p in
                    BarMark(x: .value("Period", p.date, unit: unit), y: .value("Emails", p.value))
                        .foregroundStyle(by: .value("Series", p.series))
                        .position(by: .value("Series", p.series))
                }
                .chartForegroundStyleScale(["Arrived": Color.blue, "Resolved": Color.green])
                .frame(height: 220)

                Text("Open backlog at the end of each \(model.performancePeriod == .weekly ? "week" : "month")")
                    .font(.headline)
                    .padding(.top, 6)
                Chart(backlog) { p in
                    AreaMark(x: .value("Period", p.date, unit: unit), y: .value("Open", p.value))
                        .foregroundStyle(Color.orange.opacity(0.18))
                    LineMark(x: .value("Period", p.date, unit: unit), y: .value("Open", p.value))
                        .foregroundStyle(Color.orange)
                        .symbol(Circle())
                }
                .frame(height: 200)
                Text("Weird emails (inconsistent date progression) are excluded, as in the CLI's dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
