import AppKit
import SwiftUI
import GTDCore

/// Menu-bar commands. Standard items (Edit, Window, Help, Settings…, Quit,
/// Hide) come from the system; these add the workspace, view, message and
/// workflow actions.
@MainActor
struct GTDCommands: Commands {
    @Bindable var model: AppModel

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
            Button("Dashboard") { go(.dashboard) }
                .keyboardShortcut("0")
                .disabled(model.workspace == nil)
            ForEach(Folder.allCases) { folder in
                Button(folder.title) { go(.folder(folder)) }
                    .keyboardShortcut(folder.shortcutKey)
                    .disabled(model.workspace == nil)
            }
            Button("Performance") { go(.performance) }
                .keyboardShortcut("7")
                .disabled(model.workspace == nil)
            Button("Calendar") { go(.calendar) }
                .keyboardShortcut("8")
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
            let ids = model.selectedRecords.map(\.id)
            let single = model.selectedRecord
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
            let pinTitle: String = model.selectedRecords.allSatisfy(\.isPinned) && !ids.isEmpty ? "Unpin" : "Pin"
            Button(pinTitle) {
                model.togglePin(ids)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!model.selectedRecords.contains { $0.folder != .input })
            Button("Edit Annotations") { model.beginEdit(single?.id) }
                .keyboardShortcut("e")
                .disabled(single.map { model.annotationsRefusal($0) != nil } ?? true)
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
