import SwiftUI
import GTDCore

/// Pane 2: the message list, Mail-style.
struct MessageListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let groups = model.listGroups
        VStack(spacing: 0) {
            ListHeader(title: model.listTitle, count: groups.reduce(0) { $0 + $1.records.count })
            if groups.allSatisfy({ $0.records.isEmpty }) {
                EmptyListView()
            } else {
                List(selection: $model.selection) {
                    ForEach(groups) { group in
                        if group.title.isEmpty {
                            rows(group.records)
                        } else {
                            Section(isExpanded: expanded(group.title)) {
                                rows(group.records)
                            } header: {
                                Text(group.title)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    MessageContextMenu(ids: order(ids))
                } primaryAction: { ids in
                    model.openInMail(order(ids))
                }
            }
        }
    }

    private func rows(_ records: [EmailRecord]) -> some View {
        ForEach(records) { r in
            MessageRow(record: r)
                .tag(r.id)
                .draggable(r.id)
        }
    }

    private func order(_ ids: Set<String>) -> [String] {
        model.visibleRecords.map(\.id).filter { ids.contains($0) }
    }

    private func expanded(_ title: String) -> Binding<Bool> {
        Binding(get: { !model.collapsedGroups.contains(title) },
                set: { open in
                    if open { model.collapsedGroups.remove(title) } else { model.collapsedGroups.insert(title) }
                })
    }
}

private struct ListHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
            Spacer()
            Text("\(count) email\(count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct EmptyListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isSearching ? "magnifyingglass" : "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.isSearching ? "No Results" : "No Emails")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row: correspondent and date, subject with pin/paperclip, the next
/// action as the preview line, and the age dot, account label and due date.
struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let record: EmailRecord

    var body: some View {
        let r = record
        let dimmed = model.dimOffRadar && model.isSearching && !model.isOnRadar(r)
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(r.ageClass?.color ?? .gray)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .help(r.ageDays.map { "\($0) day\($0 == 1 ? "" : "s") old" } ?? "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.listCorrespondent).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(model.dates.list(r.date.date))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 4) {
                    if r.isPinned {
                        Image(systemName: "pin.fill").foregroundStyle(.pink).imageScale(.small)
                    }
                    Text(r.subject).lineLimit(1)
                    if r.hasAttachments {
                        Image(systemName: "paperclip").foregroundStyle(.secondary).imageScale(.small)
                    }
                }
                Text(previewLine)
                    .font(.callout)
                    .foregroundStyle(r.nextAction.isEmpty ? .tertiary : .secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if model.isSearching || !(model.sidebarSelection.map(isFolderView) ?? false) {
                        Capsule().fill(.quaternary)
                            .overlay(Text(r.folder.title).font(.caption2))
                            .frame(width: 70, height: 16)
                    }
                    if let account = r.account {
                        Text(account.displayName)
                            .font(.caption)
                            .foregroundStyle(account.color)
                            .lineLimit(1)
                    }
                    if !r.dueDate.isEmpty {
                        let overdue = r.isOverdue(today: model.today)
                        Text("Due \(model.dates.isoDay(r.dueDate))")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(overdue ? Color.red.opacity(0.18) : Color.secondary.opacity(0.12)))
                            .foregroundStyle(overdue ? Color.red : Color.secondary)
                            .lineLimit(1)
                    }
                    if r.status == "weird" {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).imageScale(.small)
                            .help("Inconsistent date progression")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(dimmed ? 0.5 : 1)
    }

    private var previewLine: String {
        if record.isUnreadable { return record.parsed.error ?? "Could not be read" }
        if record.folder == .input { return "Not ingested yet" }
        return record.nextAction.isEmpty ? "No next action" : record.nextAction
    }

    private func isFolderView(_ item: SidebarItem) -> Bool {
        if case .folder = item { return true }
        return false
    }
}

/// Right-click actions for the selected rows.
struct MessageContextMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [String]

    var body: some View {
        let single = ids.count == 1 ? model.record(ids.first) : nil
        Button("Open in Mail") { model.openInMail(ids) }
        if let single {
            Button("Quick Look") { model.quickLook(single.id) }
        }
        Divider()
        Menu("Move To") {
            ForEach(Folder.allCases.filter { $0 != .input }) { folder in
                Button(moveTitle(folder)) { model.move(ids, to: folder) }
                    .disabled(!model.canMove(ids, to: folder))
            }
        }
        Button("Archive") { model.move(ids, to: .archive) }
            .disabled(!model.canMove(ids, to: .archive))
        if let single {
            Button("Close With\u{2026}") { model.beginClose(single.id) }
                .disabled(model.closeRefusal(single) != nil)
        }
        Divider()
        let records = ids.compactMap { model.record($0) }
        let pinTitle: String = records.allSatisfy(\.isPinned) && !records.isEmpty ? "Unpin" : "Pin"
        Button(pinTitle) { model.togglePin(ids) }
            .disabled(!records.contains { $0.folder != .input })
        if let single {
            Button("Edit Annotations") { model.beginEdit(single.id) }
                .disabled(model.annotationsRefusal(single) != nil)
        }
        Divider()
        Button("Reveal in Finder") { model.revealInFinder(ids) }
        Button("Copy Filename") { model.copyFilenames(ids) }
    }

    /// For a single email, say why a destination is unavailable.
    private func moveTitle(_ folder: Folder) -> String {
        guard ids.count == 1, let r = model.record(ids.first), let reason = model.moveRefusal(r, to: folder),
              reason != "Already here" else { return folder.title }
        return "\(folder.title) \u{2014} \(reason)"
    }
}
