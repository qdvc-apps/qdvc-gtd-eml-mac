import AppKit
import SwiftUI
import GTDCore

/// Thin wrappers over AppKit services.
enum Platform {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Open with the default app (Mail, for .eml files).
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Open a file in the user's default plain-text editor (`open -t`).
    static func openInTextEditor(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-t", url.path]
        try? process.run()
    }
}

extension OwnAccount {
    /// The configured terminal colour as a system colour.
    var color: Color { Color.forConfigured(colour) }
}

extension Color {
    static func forConfigured(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        case "blue": return .blue
        case "magenta": return .pink
        default: return .cyan
        }
    }
}

extension Rules.AgeClass {
    var color: Color {
        switch self {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }

    var label: String {
        switch self {
        case .green: return "Fresh"
        case .yellow: return "Ageing"
        case .red: return "Old"
        }
    }
}

extension Folder {
    /// SF Symbol for the folder, as in the sidebar.
    var symbol: String {
        switch self {
        case .input: return "tray.and.arrow.down"
        case .triage: return "tray"
        case .actionable: return "bolt"
        case .delegated: return "person.2"
        case .reference: return "books.vertical"
        case .archive: return "archivebox"
        }
    }

    /// ⌘1…⌘6 go to the folder; ⌃⌘1…⌃⌘6 move the selection there.
    var shortcutKey: KeyEquivalent { KeyEquivalent(Character(String(number))) }
}
