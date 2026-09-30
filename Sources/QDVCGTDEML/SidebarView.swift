import SwiftUI
import GTDCore

/// The source list: Overview, Workflow folders, Smart Mailboxes, the account
/// views and (when one is open) Dashboard results.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section("Overview") {
                row(.dashboard, "Dashboard", "square.grid.2x2", badge: false)
                row(.performance, "Performance", "chart.xyaxis.line", badge: false)
                row(.calendar, "Calendar", "calendar", badge: false)
            }
            Section("Workflow") {
                ForEach(Folder.allCases) { folder in
                    row(.folder(folder), folder.title, folder.symbol)
                        .dropDestination(for: String.self) { ids, _ in
                            drop(ids, on: folder)
                        }
                }
            }
            Section("Smart Mailboxes") {
                row(.dueSet, "Due Date Set", "calendar.badge.clock")
                row(.noDue, "No Due Date", "calendar.badge.minus")
                row(.pinned, "Pinned", "pin")
                ForEach(model.config.monitoredHashtags, id: \.self) { tag in
                    row(.hashtag(tag), tag, "number")
                }
            }
            if !model.config.myOwnAccounts.isEmpty {
                Section("Accounts") {
                    accountGroup(title: "Inbox", symbol: "tray.2", all: .inbox(nil)) { .inbox($0) }
                    accountGroup(title: "Sent", symbol: "paperplane", all: .sent(nil)) { .sent($0) }
                }
            }
            if let item = model.sidebarSelection, isResult(item) {
                Section("Results") {
                    row(item, model.title(for: item), "sparkle.magnifyingglass").italic()
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func isResult(_ item: SidebarItem) -> Bool {
        switch item {
        case .attention, .project, .calendarDay: return true
        default: return false
        }
    }

    @ViewBuilder
    private func accountGroup(title: String, symbol: String, all: SidebarItem,
                              item: @escaping (String) -> SidebarItem) -> some View {
        DisclosureGroup {
            ForEach(model.config.myOwnAccounts) { account in
                Label {
                    Text(account.displayName)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(account.color).imageScale(.small)
                }
                .lineLimit(1)
                .badge(model.count(item(account.emailAddress)))
                .tag(item(account.emailAddress))
            }
        } label: {
            row(all, title, symbol)
        }
    }

    private func row(_ item: SidebarItem, _ title: String, _ symbol: String, badge: Bool = true) -> some View {
        Label(title, systemImage: symbol)
            .lineLimit(1)
            .badge(badge ? model.count(item) : 0)
            .tag(item)
            .foregroundStyle(isDimmed(item) ? .secondary : .primary)
    }

    /// Off-radar folders read as secondary when dimming is on.
    private func isDimmed(_ item: SidebarItem) -> Bool {
        guard model.dimOffRadar, case .folder(let f) = item else { return false }
        return !model.radarFolders.contains(f)
    }

    /// Dragging list rows onto a folder moves them (the whole selection when
    /// a selected row is dragged).
    private func drop(_ ids: [String], on folder: Folder) -> Bool {
        var targets = ids.filter { model.recordsByID[$0] != nil }
        if targets.contains(where: { model.selection.contains($0) }) {
            targets = model.selectedRecords.map(\.id)
        }
        guard !targets.isEmpty else { return false }
        model.move(targets, to: folder)
        return true
    }
}
