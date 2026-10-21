import AppKit
import SwiftUI
import GTDCore

/// A message window: one email, opened with "Open in New Tab" and shown as a
/// native tab beside the viewer, or standalone once dragged out of the tab
/// bar. It follows the email by file name, so it keeps showing it after a
/// move. A history link clicked here shows that email in this window.
struct MessageWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Binding var ref: MessageRef?
    /// Identifies this window to the model (editing, sheets, alerts).
    @State private var context = UUID().uuidString

    var body: some View {
        content
            .frame(minWidth: 480, minHeight: 360)
            .background(WindowAccessor { model.attachMessageWindow($0, context: context) })
            .onAppear {
                if isStale { close() } else { model.setTab(context, showing: ref) }
            }
            .onChange(of: ref) { _, new in model.setTab(context, showing: new) }
            .onChange(of: model.workspace?.root.path) { _, _ in if isStale { close() } }
            .sheet(item: sheetBinding) { sheet in
                SheetContent(sheet: sheet).environment(model)
            }
            .alert(model.alert?.title ?? "", isPresented: alertBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.alert?.message ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let ref, let r = model.record(filename: ref.filename) {
            MessageDetail(record: r, context: context) { other in
                self.ref = MessageRef(workspace: ref.workspace, filename: other.filename)
            }
            .navigationTitle(r.subject)
            .focusedSceneValue(\.messageWindow, MessageWindowFocus(recordID: r.id, context: context))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.showInViewer(r.id) { openWindow(id: AppModel.viewerWindowID) }
                    } label: {
                        Label("Show in Viewer", systemImage: "sidebar.left")
                    }
                    .help("Select this email in the viewer\u{2019}s message list")
                    Button {
                        model.move([r.id], to: .archive)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .help("Move to 06-archive (\u{2303}\u{2318}A)")
                    .disabled(model.moveRefusal(r, to: .archive) != nil)
                }
            }
        } else if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("This email is no longer in the workspace").font(.title3).foregroundStyle(.secondary)
                if let ref { Text(ref.filename).font(.callout.monospaced()).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(ref?.filename ?? "Message")
        }
    }

    /// No email to show, or one from a workspace that is no longer open (a
    /// window brought back by state restoration, or after Close Workspace).
    private var isStale: Bool {
        guard let ref, let path = model.workspace?.root.path else { return true }
        return ref.workspace != path
    }

    private func close() {
        model.setTab(context, showing: nil)
        dismiss()
    }

    private var sheetBinding: Binding<ActiveSheet?> {
        Binding(get: { model.sheetContext == context ? model.activeSheet : nil },
                set: { model.activeSheet = $0 })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil && model.alertContext == context },
                set: { if !$0 { model.alert = nil } })
    }
}

/// What the menus act on while a message window is key (instead of the
/// viewer's selection).
struct MessageWindowFocus: Equatable {
    let recordID: String
    let context: String
}

private struct MessageWindowFocusKey: FocusedValueKey {
    typealias Value = MessageWindowFocus
}

extension FocusedValues {
    var messageWindow: MessageWindowFocus? {
        get { self[MessageWindowFocusKey.self] }
        set { self[MessageWindowFocusKey.self] = newValue }
    }
}

/// Hands the NSWindow a view is in to `onAttach` once it is in one (for
/// tabbing and for knowing which window is key).
struct WindowAccessor: NSViewRepresentable {
    let onAttach: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { AccessorView(onAttach: onAttach) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AccessorView: NSView {
        let onAttach: @MainActor (NSWindow) -> Void

        init(onAttach: @escaping @MainActor (NSWindow) -> Void) {
            self.onAttach = onAttach
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach(window) }
        }
    }
}
