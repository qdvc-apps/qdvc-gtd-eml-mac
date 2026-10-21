import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
                        .onDrop(of: [.plainText], delegate: SidebarDropDelegate(item: .folder(folder), model: model))
                }
            }
            Section("Smart Mailboxes") {
                row(.dueSet, "Due Date Set", "calendar.badge.clock")
                row(.noDue, "No Due Date", "calendar.badge.minus")
                row(.pinned, "Pinned", "pin")
                ForEach(model.config.monitoredHashtags, id: \.self) { tag in
                    row(.hashtag(tag), tag, "number")
                        .onDrop(of: [.plainText], delegate: SidebarDropDelegate(item: .hashtag(tag), model: model))
                        .help("Drop emails here to set their next action to \(tag) (only emails with no next action)")
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
            .background {
                if model.dropTarget == item {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.22))
                        .padding(.horizontal, -6)
                        .padding(.vertical, -3)
                }
            }
    }

    /// Off-radar folders read as secondary when dimming is on.
    private func isDimmed(_ item: SidebarItem) -> Bool {
        guard model.dimOffRadar, case .folder(let f) = item else { return false }
        return !model.radarFolders.contains(f)
    }

}

/// Drops from the message list onto a Workflow folder (Move To) or a hashtag
/// mailbox (the tag becomes the next action of emails that have none).
///
/// Whether a drop would do anything is decided while hovering, from the rows
/// recorded when the drag started: an entry that would refuse is not
/// highlighted, shows the not-allowed pointer, and says why in the window
/// subtitle, so nothing has to be undone or dismissed afterwards. Delegate
/// callbacks arrive on the main thread.
struct SidebarDropDelegate: DropDelegate {
    let item: SidebarItem
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        _ = evaluate()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        evaluate() ? DropProposal(operation: isFolder ? .move : .copy) : DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        let item = self.item
        MainActor.assumeIsolated {
            if model.dropTarget == item { model.dropTarget = nil }
            model.dropHint = nil
            NSCursor.arrow.set()
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let item = self.item
        let model = self.model
        let accepted = MainActor.assumeIsolated { () -> Bool in
            NSCursor.arrow.set()
            return model.prepareDrop(on: item)
        }
        guard accepted, let provider = info.itemProviders(for: [.plainText]).first else {
            MainActor.assumeIsolated { model.finishDrop(payload: nil) }
            return false
        }
        // Only Sendable values cross into the loader's callback: the drop
        // itself waits on the (main-actor) model.
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let payload = (object as? NSString).map { $0 as String }
            Task { @MainActor in model.finishDrop(payload: payload) }
        }
        return true
    }

    private var isFolder: Bool {
        if case .folder = item { return true }
        return false
    }

    /// Update the highlight and hint; true when the drop would be accepted.
    private func evaluate() -> Bool {
        let item = self.item
        return MainActor.assumeIsolated {
            let refusal = model.dropRefusal(model.draggedIDs, on: item)
            model.dropTarget = refusal == nil ? item : nil
            model.dropHint = refusal.flatMap { $0.isEmpty ? nil : $0 }
            // The pointer AppKit shows over a destination that cannot take
            // the drop (HIG: Pointers, "Operation not allowed").
            if refusal != nil { NSCursor.operationNotAllowed.set() }
            return refusal == nil
        }
    }
}
