import AppKit
import QuickLook
import SwiftUI
import GTDCore

/// The main window: a source-list sidebar and, to its right, either a
/// Mail-style message list with its reading pane, or the Dashboard or
/// Performance view. The sidebar is the same instance throughout, so it never
/// jumps when switching views.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.workspace == nil {
                WelcomeView()
            } else {
                MainSplitView()
                    .dropDestination(for: URL.self) { urls, _ in
                        let emls = urls.filter { $0.pathExtension.lowercased() == "eml" }
                        guard !emls.isEmpty else { return false }
                        model.importFiles(emls)
                        return true
                    }
            }
        }
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.statusLine)
        .overlay {
            if model.isLoading {
                ProgressView("Loading workspace\u{2026}")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .quickLookPreview($model.quickLookURL)
        .sheet(item: $model.activeSheet) { sheet in
            SheetContent(sheet: sheet)
                .environment(model)
        }
        .alert(model.alert?.title ?? "",
               isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert?.message ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.appBecameActive()
        }
    }
}

struct MainSplitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            // The banners sit in the layout above the content, not in a
            // safe-area inset: HSplitView (AppKit's NSSplitView) ignores
            // SwiftUI's insets, so an inset banner would overlap the list's
            // title and slide up under the toolbar.
            VStack(spacing: 0) {
                BannerStack()
                Group {
                    if model.isSearching || (model.sidebarSelection?.isMailbox ?? true) {
                        MailboxView()
                    } else if model.sidebarSelection == .performance {
                        PerformanceView()
                    } else {
                        DashboardView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search all folders"))
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        MainToolbar(model: model).content
    }
}

/// The list and reading pane, side by side.
struct MailboxView: View {
    var body: some View {
        HSplitView {
            MessageListView()
                .frame(minWidth: 320, idealWidth: 440, maxWidth: 760)
            ReadingPane()
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The window's toolbar items (built by `MainSplitView`). Main-actor
/// isolated like a view's body, since it reads the model.
@MainActor
struct MainToolbar {
    @Bindable var model: AppModel

    @ToolbarContentBuilder
    var content: some ToolbarContent {
        let ids = model.selectedRecords.map(\.id)
        let single = model.selectedRecord
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.ingest()
            } label: {
                Label("Ingest", systemImage: "tray.and.arrow.down")
            }
            .help("Rename and file the emails in 01-input into Triage (\u{21E7}\u{2318}N)")
            .badge(model.inputCount)

            Menu {
                ForEach(Folder.allCases.filter { $0 != .input }) { folder in
                    Button {
                        model.move(ids, to: folder)
                    } label: {
                        Label(folder.title, systemImage: folder.symbol)
                    }
                    .disabled(!model.canMove(ids, to: folder))
                }
            } label: {
                Label("Move To", systemImage: "folder")
            }
            .help("Move the selection to another folder (\u{2303}\u{2318}1\u{2013}6)")
            .disabled(ids.isEmpty)

            Button {
                model.move(ids, to: .archive)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .help("Move to 06-archive (\u{2303}\u{2318}A)")
            .disabled(!model.canMove(ids, to: .archive))

            Button {
                model.beginClose(single?.id)
            } label: {
                Label("Close With", systemImage: "checkmark.circle")
            }
            .help("Archive this email and record which email closed it (\u{2325}\u{2318}K)")
            .disabled(single.map { model.closeRefusal($0) != nil } ?? true)

            Button {
                model.togglePin(ids)
            } label: {
                Label("Pin", systemImage: "pin")
            }
            .help("Pin or unpin (\u{21E7}\u{2318}L)")
            .disabled(!model.selectedRecords.contains { $0.folder != .input })

            Menu {
                Picker("Sort By", selection: $model.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("Ascending", isOn: $model.sortAscending)
                Toggle("Show Date Headings", isOn: $model.showDateHeadings)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort the message list")

            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload changed files and workspace.yml (\u{2318}R)")
        }
    }
}

/// Notices above the content: pending input, date stamps to review, and a
/// workspace.yml that could not be read.
struct BannerStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.configError {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .red,
                       text: "workspace.yml could not be read, so defaults are in use: \(error)",
                       action: "Open workspace.yml") { model.openConfigFile() }
            }
            if model.inputCount > 0 && model.sidebarSelection != .performance {
                Banner(symbol: "tray.and.arrow.down.fill", tint: .accentColor,
                       text: "\(model.inputCount) email\(model.inputCount == 1 ? " is" : "s are") waiting in Input.",
                       action: "Ingest") { model.ingest() }
            }
            if model.needsDateReview {
                Banner(symbol: "calendar.badge.exclamationmark", tint: .orange,
                       text: model.autofix.blockers.isEmpty
                           ? "\(model.autofix.fixes.count) date stamp\(model.autofix.fixes.count == 1 ? " is" : "s are") missing or inconsistent."
                           : "\(model.autofix.blockers.count) email\(model.autofix.blockers.count == 1 ? " needs" : "s need") manual attention before date stamps can be fixed.",
                       action: "Review\u{2026}") { model.beginReviewDateStamps() }
            }
        }
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button(action, action: perform).controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // A colour background would otherwise extend into the safe area,
        // i.e. up behind the toolbar and window title.
        .background(tint.opacity(0.10), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Picks the view for the sheet that is open.
private struct SheetContent: View {
    let sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .closeWith(let id): CloseWithSheet(recordID: id)
        case .reviewDateStamps: ReviewDateStampsSheet()
        case .checkMetadata(let report): CheckMetadataSheet(report: report)
        }
    }
}

/// Shown when no workspace is open.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.full")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("QDVC GTD EML")
                .font(.largeTitle.weight(.semibold))
            Text("Open a gtd-eml working directory \u{2014} the folder containing 01-input \u{2026} 06-archive and metadata.csv \u{2014} to work through your email.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Open Workspace\u{2026}") { model.chooseWorkspace() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            if !model.recentWorkspaces.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.headline)
                    ForEach(Array(model.recentWorkspaces.prefix(5)), id: \.self) { path in
                        Button((path as NSString).abbreviatingWithTildeInPath) {
                            model.open(URL(fileURLWithPath: path, isDirectory: true))
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
