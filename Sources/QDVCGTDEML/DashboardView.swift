import SwiftUI
import GTDCore

/// The Overview → Dashboard page (the web UI's overview pane).
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let o = model.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Dashboard").font(.largeTitle.weight(.semibold))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    ForEach(Folder.allCases) { folder in
                        Button {
                            model.sidebarSelection = .folder(folder)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(folder.title, systemImage: folder.symbol)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("\(o.counts[folder] ?? 0)")
                                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .help("Show \(folder.rawValue)")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Needs Attention").font(.title3.weight(.semibold))
                    ForEach(o.attention) { figure in
                        Button {
                            model.sidebarSelection = .attention(figure.key)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(figure.count)")
                                    .font(.title3.weight(.semibold))
                                    .monospacedDigit()
                                    .frame(minWidth: 36, alignment: .trailing)
                                    .foregroundStyle(figure.count > 0 ? Color.primary : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(figure.label.capitalizedFirst)
                                    Text(figure.hint).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if figure.count > 0 {
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(figure.count == 0)
                        Divider()
                    }
                }

                if !o.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Projects").font(.title3.weight(.semibold))
                        ForEach(o.projects) { project in
                            Button {
                                model.sidebarSelection = .project(project.name)
                            } label: {
                                HStack {
                                    Text(project.name)
                                    Spacer()
                                    Text("\(project.ids.count)").monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("\(o.total) emails, \(o.tracked) tracked in metadata.csv. Statuses: "
                     + ["ongoing", "resolved", "weird", "untracked"].map { "\(o.statuses[$0] ?? 0) \($0)" }
                        .joined(separator: ", ") + ".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
