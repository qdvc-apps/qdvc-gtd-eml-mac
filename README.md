# QDVC GTD EML for macOS

A native SwiftUI app for macOS 14 (Sonoma) and later for working a Getting
Things Done workflow over `.eml` files. It opens a
[qdvc-gtd-eml](https://github.com/qdvc-apps/qdvc-gtd-eml) workspace, shows it in
a Mail-style window, and performs the command-line tool's workflow actions
directly on the workspace, producing exactly the same files and
`metadata.csv`. Neither needs the other.

- **Mail-style window:** Workflow folders (Input … Archive), Smart Mailboxes
  (due date set, no due date, pinned, one per monitored hashtag), Inbox and
  Sent per own account, a Dashboard, a Performance view and a Calendar.
- **Message list** with the next action as the preview line, age dots, account
  labels, due-date capsules and collapsible date headings.
- **Reading pane** with editable annotations (next action, project, due
  date, flags, notes), the workflow trail and metrics, and the thread split
  into its quoted messages.
- **Actions:** Ingest (⇧⌘N), Move To (⌃⌘1–6 or drag to a folder), Archive
  (⌃⌘A), Close With… (⌥⌘K), Pin/Unpin (⇧⌘L), Edit Annotations (⌘E), Review
  Date Stamps… (`workflow_autofix`), Check Metadata… (`metadata_check`).
  The CLI's refusals apply, with its wording.
- **Performance:** the open backlog and weekly/monthly throughput, per account.
- **Calendar:** a month heatmap of how many emails had something happen each
  day (received, quoted, or a workflow stamp); click a day to list them.
- Drop `.eml` files on the window to add them to Input.

## Build and run

```
swift build
swift run QDVCGTDEML          # or open the folder in Xcode
swift test                   # parity tests against the Python edition
scripts/build-app.sh         # "build/QDVC GTD EML.app", ad-hoc signed
scripts/build-app.sh --install
```

No Apple Developer account is needed. Try it on `sample-workspace/`.

## Workspace settings

Accounts, monitored hashtags, the age-colour thresholds and the filename
length are read from `workspace.yml` in the workspace, so the CLI and the app
agree (see [docs/WORKSPACE_CONFIG_REQUEST.md](docs/WORKSPACE_CONFIG_REQUEST.md)).
The app's own preferences (date format, time zone, on-radar folders) are in
Settings (⌘,).

## Documentation

- [docs/DESIGN.md](docs/DESIGN.md): the design and the decisions taken.
- [docs/FILE_FORMAT.md](docs/FILE_FORMAT.md): the workspace format.
- [docs/MAINTENANCE.md](docs/MAINTENANCE.md): code layout, preserved
  behaviour, tests.

## License

No license has been chosen yet. Add a `LICENSE` file before publishing.
