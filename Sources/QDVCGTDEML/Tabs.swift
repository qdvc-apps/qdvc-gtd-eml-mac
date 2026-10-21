import AppKit
import SwiftUI
import GTDCore

/// Creates message windows: plain AppKit windows hosting `MessageWindow`,
/// which the model adds to a tab group before showing. They are not a
/// SwiftUI WindowGroup, which would give the tab bar a "+" button for a new,
/// empty window, and would bring old message windows back at launch.
@MainActor
enum MessageWindows {
    static func make(_ ref: MessageRef, context: String, model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: MessageWindow(ref: ref, context: context).environment(model))
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // An empty unified toolbar, so the title bar is as tall as the
        // viewer's and the content does not jump when switching tabs.
        window.toolbar = NSToolbar(identifier: "message")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setContentSize(NSSize(width: 900, height: 760))
        window.title = model.record(filename: ref.filename)?.subject ?? ref.filename
        return window
    }
}

/// A message window: one email, opened with "Open in New Tab" and shown as a
/// native tab beside the viewer, or standalone once dragged out of the tab
/// bar. It follows the email by file name, so it keeps showing it after a
/// move. A history link clicked here shows that email in this window.
struct MessageWindow: View {
    @Environment(AppModel.self) private var model
    @State private var ref: MessageRef
    /// Identifies this window to the model (editing, sheets, alerts).
    let context: String

    init(ref: MessageRef, context: String) {
        _ref = State(initialValue: ref)
        self.context = context
    }

    var body: some View {
        content
            .frame(minWidth: 480, minHeight: 360)
            .onChange(of: ref) { _, new in model.setTab(context, showing: new) }
            .onChange(of: title, initial: true) { _, new in model.setTabTitle(context, new) }
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
        if let r = model.record(filename: ref.filename) {
            MessageDetail(record: r, context: context) { other in
                ref = MessageRef(workspace: ref.workspace, filename: other.filename)
            }
        } else if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("This email is no longer in the workspace").font(.title3).foregroundStyle(.secondary)
                Text(ref.filename).font(.callout.monospaced()).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The window's (and tab's) title.
    private var title: String { model.record(filename: ref.filename)?.subject ?? ref.filename }

    private var sheetBinding: Binding<ActiveSheet?> {
        Binding(get: { model.sheetContext == context ? model.activeSheet : nil },
                set: { model.activeSheet = $0 })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil && model.alertContext == context },
                set: { if !$0 { model.alert = nil } })
    }
}

/// Hands the NSWindow a view is in to `onAttach` once it is in one (the
/// viewer registers its window this way, for tabbing and for knowing which
/// window is key).
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
