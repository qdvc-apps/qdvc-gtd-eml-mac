import SwiftUI
import GTDCore

/// Reader preferences. Workspace settings (accounts, hashtags, age colours,
/// filename length) live in the workspace's own workspace.yml, shared with
/// the CLI; the Workspace tab shows them and opens the file.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            WorkspaceSettings()
                .tabItem { Label("Workspace", systemImage: "folder") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Date format:", selection: $model.dateStyle) {
                ForEach(DateStyle.allCases) { Text($0.example).tag($0) }
            }
            Picker("Time zone:", selection: $model.timeZoneID) {
                Text("System (\(TimeZone.current.identifier))").tag("")
                Divider()
                ForEach(Self.zones, id: \.self) { Text($0).tag($0) }
            }
            Picker("Quoted times with no zone:", selection: $model.naiveDates) {
                ForEach(NaiveDates.allCases) { Text($0.title).tag($0) }
            }
            .help("How to show times inside quoted messages (\u{201C}Sent: 3 August 2026 12:34\u{201D}) that name no time zone.")

            Section {
                ForEach(Folder.allCases) { folder in
                    Toggle(folder.title, isOn: Binding(
                        get: { model.radarFolders.contains(folder) },
                        set: { on in
                            if on { model.radarFolders.insert(folder) } else { model.radarFolders.remove(folder) }
                        }))
                }
                Toggle("Dim emails outside these folders", isOn: $model.dimOffRadar)
            } header: {
                Text("On the radar")
            } footer: {
                Text("Smart Mailboxes and the Inbox/Sent views only list emails in these folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Reopen the last workspace at launch", isOn: $model.reopenLast)
        }
    }
}

private struct WorkspaceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let ws = model.workspace {
                Text("These settings belong to the workspace, so the gtd command-line tool uses them too. Change them by editing \(WorkspaceConfig.fileName); the app reloads it on Refresh.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.configError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Workspace", (ws.root.path as NSString).abbreviatingWithTildeInPath)
                    row("Filename length", "\(model.config.maxFilenameChars) characters")
                    row("Age colours", "green under \(model.config.greenMaxDays) days, yellow under \(model.config.yellowMaxDays)")
                    row("Accounts", model.config.myOwnAccounts.isEmpty ? "none"
                        : model.config.myOwnAccounts.map { "\($0.displayName) (\($0.emailAddress))" }.joined(separator: "\n"))
                    row("Hashtags", model.config.monitoredHashtags.isEmpty ? "none"
                        : model.config.monitoredHashtags.joined(separator: ", "))
                }
                HStack {
                    Button("Open \(WorkspaceConfig.fileName)") { model.openConfigFile() }
                    Button("Reload") { model.refresh() }
                }
            } else {
                Text("Open a workspace to see its settings.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}
