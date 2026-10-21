import AppKit
import SwiftUI
import GTDCore

/// Menu-bar commands. Standard items (Edit, Window, Help, Settings…, Quit,
/// Hide) come from the system; these add the workspace, view, message and
/// workflow actions.
@MainActor
struct GTDCommands: Commands {
    @Bindable var model: AppModel
    /// Set while a message window (tab) is key: the Message menu then acts
    /// on its email rather than the viewer's selection.
    @FocusedValue(\.messageWindow) var focusedMessage: MessageWindowFocus?
    @Environment(\.openWindow) var openWindow

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("Open Workspace\u{2026}") { model.chooseWorkspace() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentWorkspaces, id: \.self) { path in
                    Button((path as NSString).abbreviatingWithTildeInPath) {
                        model.open(URL(fileURLWithPath: path, isDirectory: true))
                    }
                }
                if !model.recentWorkspaces.isEmpty {
                    Divider()
                    Button("Clear Menu") { model.clearRecents() }
                }
            }
            Divider()
            Button("Add Emails to Input\u{2026}") { model.chooseFilesToAdd() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model.workspace == nil)
            Button("Open workspace.yml") { model.openConfigFile() }
                .disabled(model.workspace == nil)
            Button("Reveal Workspace in Finder") { model.revealWorkspace() }
                .disabled(model.workspace == nil)
            Divider()
            Button("Close Workspace") { model.closeWorkspace() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.workspace == nil)
        }

        CommandGroup(after: .toolbar) {
            // No shortcuts: \u{2318}1\u{2013}\u{2318}9 select tabs (Window menu).
            Button("Dashboard") { go(.dashboard) }
                .disabled(model.workspace == nil)
            ForEach(Folder.allCases) { folder in
                Button(folder.title) { go(.folder(folder)) }
                    .disabled(model.workspace == nil)
            }
            Button("Performance") { go(.performance) }
                .disabled(model.workspace == nil)
            Button("Calendar") { go(.calendar) }
                .disabled(model.workspace == nil)
            Divider()
            Toggle("Show Date Headings", isOn: $model.showDateHeadings)
            Menu("Sort By") {
                Picker("Sort By", selection: $model.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Toggle("Ascending", isOn: $model.sortAscending)
            }
            Divider()
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r")
                .disabled(model.workspace == nil)
            Divider()
        }

        CommandMenu("Message") {
            let focus = focusedMessage
            let ids: [String] = focus.map { [$0.recordID] } ?? model.selectedRecords.map(\.id)
            let single: EmailRecord? = focus != nil ? model.record(focus?.recordID) : model.selectedRecord
            let records = ids.compactMap { model.record($0) }
            Button(ids.count > 1 ? "Open in New Tabs" : "Open in New Tab") {
                model.openInNewTab(ids) { openWindow(id: AppModel.messageWindowID, value: $0) }
            }
            // A message window already shows its email.
            .disabled(ids.isEmpty || focus != nil)
            Button("Open in Mail") { model.openInMail(ids) }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(ids.isEmpty)
            Button("Quick Look") { model.quickLook(single?.id) }
                .keyboardShortcut("y")
                .disabled(single == nil)
            Button("Reveal in Finder") { model.revealInFinder(ids) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(ids.isEmpty)
            Button("Copy Filename") { model.copyFilenames(ids) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(ids.isEmpty)
            Divider()
            Menu("Move To") {
                ForEach(Folder.allCases.filter { $0 != .input }) { folder in
                    Button(folder.title) { model.move(ids, to: folder) }
                        .keyboardShortcut(folder.shortcutKey, modifiers: [.command, .control])
                        .disabled(!model.canMove(ids, to: folder))
                }
            }
            .disabled(ids.isEmpty)
            Button("Archive") { model.move(ids, to: .archive) }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(!model.canMove(ids, to: .archive))
            Button("Close With\u{2026}") { model.beginClose(single?.id) }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(single.map { model.closeRefusal($0) != nil } ?? true)
            Divider()
            let pinTitle: String = records.allSatisfy(\.isPinned) && !ids.isEmpty ? "Unpin" : "Pin"
            Button(pinTitle) {
                model.togglePin(ids)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!records.contains { $0.folder != .input })
            if !model.config.monitoredHashtags.isEmpty {
                Menu(model.tagMenuTitle(ids)) {
                    ForEach(model.config.monitoredHashtags, id: \.self) { tag in
                        Button(tag) { model.applyHashtag(ids, tag: tag) }
                    }
                }
                .disabled(!model.canTag(ids))
            }
            Button("Edit Annotations") {
                model.beginEdit(single?.id, context: focus?.context ?? AppModel.viewerContext)
            }
            .keyboardShortcut("e")
            .disabled(single.map { model.annotationsRefusal($0) != nil } ?? true)
        }

        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Reopen Closed Tab") {
                model.reopenClosedTab { openWindow(id: AppModel.messageWindowID, value: $0) }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!model.canReopenTab)
            Menu("Select Tab") {
                ForEach(1...9, id: \.self) { n in
                    Button("Tab \(n)") { Platform.selectTab(n) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
            }
        }

        CommandMenu("Workflow") {
            Button("Ingest Input") { model.ingest() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.workspace == nil)
            Divider()
            Button("Review Date Stamps\u{2026}") { model.beginReviewDateStamps() }
                .disabled(model.workspace == nil)
            Button("Check Metadata\u{2026}") { model.beginCheckMetadata() }
                .disabled(model.workspace == nil)
        }
    }

    private func go(_ item: SidebarItem) {
        model.sidebarSelection = item
        model.searchText = ""
    }
}
