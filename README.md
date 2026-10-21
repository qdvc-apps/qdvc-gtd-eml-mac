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
  date, flags, notes), the email's history chain (emails linked by
  "Closed with", click one to jump to it), the workflow trail and metrics,
  and the thread split into its quoted messages.
- **Actions:** Ingest (⇧⌘N), Move To (⌃⌘1–6 or drag to a folder), Archive
  (⌃⌘A), Close With… (⌥⌘K), Pin/Unpin (⇧⌘L), Edit Annotations (⌘E), Review
  Date Stamps… (`workflow_autofix`), Check Metadata… (`metadata_check`).
  The CLI's refusals apply, with its wording.
- **Drag to a hashtag mailbox** (or Message → Set Next Action ▸) to make
  the hashtag the next action of emails that have none; one that already
  has a next action is refused.
- **Performance:** the open backlog and weekly/monthly throughput, per account.
- **Calendar:** a month heatmap of how many emails had something happen each
  day (received, quoted, or a workflow stamp); click a day to list them.
- Drop `.eml` files on the window to add them to Input.

## Requirements

- macOS 14 Sonoma or later.
- Xcode 16 or later (free from the Mac App Store); Xcode 26 or later for the
  Liquid Glass look. Full Xcode is needed, not just the Command Line Tools:
  from Xcode 27, SwiftUI's `@State` is a macro whose compiler plugin
  (SwiftUIMacros) ships only with Xcode, so a Command Line Tools or swift.org
  toolchain fails with "plugin for module 'SwiftUIMacros' not found".
- No paid Apple Developer account.

## Build and run

```
scripts/build-app.sh            # "build/QDVC GTD EML.app", ad-hoc signed
scripts/build-app.sh --install  # …and copy it to ~/Applications
```

`scripts/build-app.sh` builds with Xcode's toolchain even when
`xcode-select` points at the Command Line Tools: it picks the newest Xcode
installed, and says which Xcode and macOS SDK it is using (warning if the
SDK predates Liquid Glass). It also records that SDK in the app's binary,
which is what turns on Liquid Glass (`swift build` alone writes the
deployment target there, 14.0, so a `swift run` build keeps the classic
look). Check a build with
`vtool -show-build "build/QDVC GTD EML.app/Contents/MacOS/QDVCGTDEML"`:
`sdk` should be 26.0 or later.

To run or test from the command line, point the tools at Xcode the same
way, once per Terminal session or for good:

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# or: sudo xcode-select --switch /Applications/Xcode.app
swift run QDVCGTDEML            # build and launch (debug)
swift test                      # parity tests against the Python edition
```

Or open the folder in Xcode and run the **QDVCGTDEML** scheme. Try it on
`sample-workspace/`.

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
