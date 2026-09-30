# QDVC GTD EML for macOS — Design Proposal

Status: **draft, awaiting answers to the open questions in §9.**

This document proposes how the macOS edition of
[qdvc-gtd-eml](https://github.com/qdvc-apps/qdvc-gtd-eml) should look and
behave. It follows the approach of the QDVC Nice Mail and QDVC Bibliotheca
macOS ports: a pure-Swift port of the Python core with committed parity
fixtures, a SwiftUI/AppKit front-end, no Xcode project file, and an
ad-hoc-signed bundle built by `scripts/build-app.sh`.

---

## 1. Principles

- **The workspace is the contract.** The app reads and writes the same six
  folders and the same `metadata.csv` as the CLI, byte for byte, so either
  can be used on the same workspace at any time. It does not need the Python
  code at run time.
- **The CLI's rules are the app's rules.** Every refusal the CLI makes is a
  refusal here too: `alloc` never overwrites a set `ds_*` stamp, `close`
  requires the other email to exist and refuses an already-archived email,
  `ds_*` stamps are never hand-editable, and `workflow_autofix` applies a
  whole reviewed batch or nothing. In the GUI, a refused action is shown as a
  disabled menu item with the reason in its help tag, or as an alert that
  explains what the CLI would have said.
- **Writes happen immediately.** As in the sibling ports, every change is
  written to disk at once (atomically). There is no document to save.
- **Look like Mail, where Mail has an answer.** People already know how
  Mail's sidebar, message list, reading pane, flagging, moving and archiving
  work. Where a GTD concept has a close Mail equivalent, the app borrows
  Mail's placement, icon style and keyboard shortcut.

## 2. Window layout

One window, one `NavigationSplitView` with three columns, like Mail and like
Bibliotheca's `MainSplitView`:

1. **Sidebar** (source list, collapsible with ⌃⌘S / View → Hide Sidebar).
2. **Message list** (the "content" column).
3. **Reading pane** (the "detail" column).

The sidebar sections mirror the web UI's categories, relabelled with Mail's
vocabulary:

| Section | Entries | SF Symbol ideas |
| --- | --- | --- |
| Overview | Dashboard, Performance | `rectangle.3.group`, `chart.bar.xaxis` |
| Workflow | Input, Triage, Actionable, Delegated, Reference, Archive (with counts) | `tray.and.arrow.down`, `tray`, `bolt`, `person.2`, `books.vertical`, `archivebox` |
| Smart Mailboxes | Due Date Set, No Due Date, Pinned, one per monitored hashtag | `calendar.badge.clock`, `calendar`, `pin`, `number` |
| Accounts | per own account: Inbox and Sent (only when accounts are configured) | `envelope`, `paperplane` |

Dashboard and Performance replace the list and reading pane with a single
scrolling overview (as Bibliotheca's non-list tabs keep the split view's
shape), so the sidebar never jumps.

### 2.1 Message list

Mail-style rows rather than a `Table`, because a GTD row carries more than a
table cell can show well:

- **Line 1:** correspondent (bold) and date/time on the right.
- **Line 2:** subject, with a pin glyph if pinned and a paperclip if it has
  attachments.
- **Line 3:** the next action in secondary colour (the "preview line"), or
  *No next action* in tertiary colour for an open email without one.
- An **age dot** in the leading gutter where Mail shows its unread dot,
  coloured green / yellow / red by the same thresholds as `gtd list`.
- The **own-account label** in that account's configured colour, and a
  **due-date capsule** that turns red once overdue.
- **Date headings** (Today, Yesterday, This Week, Last Week, …) exactly as the
  web UI buckets them, collapsible; a View menu toggle turns grouping off.
- Sort menu (View → Sort By): Date, Due Date, Subject, Correspondent, Folder,
  ascending or descending.

Multiple selection is supported for Move, Archive, Pin and Unpin, as in Mail.

### 2.2 Reading pane

Same order as the web UI, because annotations are the point of a GTD system:

1. **Pills:** age (colour-matched to the list dot), folder, account, status
   (ongoing / resolved / weird), due date.
2. **Subject** as the title.
3. **Annotations card:** Next Action, Project (with a combo box of existing
   projects), Due Date (a date picker, plus a free-text escape hatch because
   the CLI allows free text), Flags, and Notes. Fields are edited in place
   and written on commit (Return, or leaving the field).
4. **Workflow trail** (`ds_*` stamps) and the email's metrics, in a
   disclosure group.
5. **Message history:** the thread split into collapsible blocks, each with
   its own From / To / Date and attachments, nested quotes indented and
   collapsed, exactly as the web UI does.

Bodies are rendered as plain text (HTML parts converted to text), for the
same reason as the web UI: no remote content, no sender markup.

## 3. Actions (the CLI, as Mail-style commands)

| CLI | Menu command | Toolbar | Shortcut | Mail precedent |
| --- | --- | --- | --- | --- |
| `list` (ingest) | Mailbox → Ingest New Files | Ingest (`tray.and.arrow.down`) | ⇧⌘N | Get All New Mail |
| `alloc <dest>` | Message → Move To ▸ folder | Move To (menu) | ⌃⌘1 – ⌃⌘6 | Move to Favourite Mailbox |
| `alloc archive` | Message → Archive | Archive | ⌃⌘A | Archive |
| `close … with …` | Message → Close With… (sheet: pick the closing email) | Close With… | ⌥⌘K | — |
| `pin` / `unpin` | Message → Pin / Unpin | Pin | ⇧⌘L | Flag |
| `metadata set` | inline in the reading pane; Message → Edit Annotations… (⌘E) | — | ⌘E | — |
| `workflow_autofix` | Mailbox → Review Date Stamps… (sheet listing every proposed stamp, one Apply button) | banner | — | — |
| `metadata_check` | Mailbox → Check Metadata… (report sheet) | — | — | — |
| `view` | Message → Open in Mail / Quick Look | — | ⌘↩ / ⌘Y | Open Message |
| `search` | toolbar search field (all folders, including quoted text) | Search | ⌥⌘F | Mailbox Search |
| `stats` | the sidebar counts and the Dashboard | — | — | — |

Also:

- **Drag and drop:** dragging messages onto a Workflow folder in the sidebar
  is `alloc`, as dragging to a mailbox is in Mail. Dropping `.eml` files from
  Finder or Mail onto the window copies them into `01-input`.
- **Go to folder:** ⌘1 – ⌘6 select the six Workflow folders, as ⌘1… select
  favourite mailboxes in Mail. ⌘0 is the Dashboard.
- **Context menus** on rows repeat the Message menu.
- **No undo for moves.** Undoing an `alloc` would mean clearing a `ds_*`
  stamp, which nothing in the CLI ever does. Instead, moving is disabled
  (with the reason) when it would be refused, and there is nothing to
  confirm otherwise, which matches both Mail and the CLI.
- **Autofix banner:** when `plan_autofix` has outstanding fixes or blockers,
  a thin banner above the message list says so and offers Review…; the
  Performance view shows the same message instead of metrics, mirroring
  `generate_dashboard`'s refusal. Browsing and all other actions keep
  working.

## 4. Settings (⌘,)

- **General:** ingest automatically when the workspace opens and on Refresh
  (see §9), date format (the web UI's three), timezone for `.eml` dates, and
  how to read quoted headers with no zone.
- **Accounts and Tags:** `my_own_accounts` (address, display name, colour)
  and `monitored_hashtags`, depending on the answer in §9.
- **Smart Mailboxes:** which folders are *on radar*, and whether off-radar
  mail is greyed out.

Appearance (light/dark) follows the system, as native apps do; the web UI's
Warm/Neutral tone and font-stack overrides have no Mac equivalent and are
dropped.

## 5. Modules (planned)

`GTDCore` (Foundation only, unit-tested, builds on Linux):

| File | Responsibility | Origin in the Python edition |
| --- | --- | --- |
| `TextSupport.swift` | Python-compatible string helpers, atomic file IO | — |
| `CSV.swift` | reader and writer matching Python's `csv` (excel dialect) | Python's `csv` |
| `Config.swift` | folders, aliases, stamp fields, account and hashtag normalisation | `config.py` |
| `MIME.swift` | RFC 5322 headers, RFC 2047 words, multipart walking, base64 / QP, charsets | Python's `email` package |
| `EmailUtil.swift` | body text, HTML to text, correspondents, message refs, own-account matching | `emailutil.py` |
| `Naming.swift` | slugs, filenames, uniqueness with a protected ref suffix | `naming.py` |
| `Metadata.swift` | load, sync, get/set, flags, stamps | `metadata.py` |
| `Workspace.swift` | folders, listing, find, move, ingest, alloc, close, pin | `fs.py`, `ingest.py`, `commands/*.py` |
| `Metrics.swift` | autofix plan, status, `ttS` / `Td` / `Wd` / `tttR`, stages | `metrics.py` |
| `Thread.swift` | split a body into its quoted history | `thread.py` |
| `Overview.swift` | Dashboard figures and the lists behind them | `site.py` |
| `Performance.swift` | backlog, flow series, percentiles, hit rates, Sankey data | `dashboard.py` (the numbers, not the HTML) |

`QDVCGTDEML` (the app): `GTDApp`, `Commands`, `ContentView`,
`SidebarView`, `MessageListView`, `ReadingPane`, `ThreadView`,
`DashboardView`, `PerformanceView` (Swift Charts), `Sheets`, `AppModel`,
`Prefs`, `SettingsView`, `Platform`.

## 6. Parity testing

As in the sibling ports, `tools/make_fixtures.py` runs the Python edition's
code over a set of generated `.eml` files and records the outputs in
`Tests/GTDCoreTests/Fixtures/parity.json`: parsed headers and bodies, message
refs, generated filenames (including the ref-protected truncation and `-2`
collisions), correspondents, thread splits, autofix plans, metrics, overview
figures, and `metadata.csv` bytes after scripted sequences of ingest / alloc /
close / pin / set operations.

The riskiest piece is `MIME.swift`: Python's `email` parser is extremely
lenient, and the filenames the CLI generates depend on its exact decoding of
the `Subject` and `Date` headers. The fixture set will lean heavily on awkward
real-world headers (encoded words, folded lines, odd charsets, missing dates).

## 7. Performance view

Swift Charts covers the box plots (drawn with `RuleMark` and `RectangleMark`),
the stacked composition bars, the throughput lines and the backlog histogram.
It has no Sankey, so the flow diagram would be a hand-drawn `Canvas` using the
same stage-collapsing rules as `dashboard.build_sankey`. This is the largest
single piece of UI work and is a candidate for a later phase (see §9).

## 8. Not planned

- `generate_dashboard` and `export masterdetail_yaml`: the app itself is the
  dashboard, and export is a batch job the CLI already does well.
- The mobile build.
- Any network access.

## 9. Open questions

1. **Where do settings come from?** The CLI reads `config.yml` next to its
   own code, not from the workspace, so pointing the app at a workspace does
   not reveal `my_own_accounts`, `monitored_hashtags`, the age thresholds or
   `max_filename_chars` (which changes the filenames `ingest` produces).
   Options: (a) the app's own Settings, per workspace, in `UserDefaults`;
   (b) the user points the app at a `config.yml` once and it reads it,
   read-only; (c) both, with `config.yml` taking precedence when chosen.
2. **Which actions?** Proposed: ingest, alloc, close, pin/unpin, metadata
   edit, workflow autofix, metadata check. `generate_dashboard` and `export`
   are left out.
3. **Performance view in the first version, or a later phase?**
4. **Automatic ingest?** `gtd list` ingests on every run. Should the app
   ingest when it opens a workspace and on Refresh, or only on the explicit
   Ingest command (with an opt-in setting for the automatic behaviour)?
5. **Names:** repository `qdvc-gtd-eml-mac`, app "QDVC GTD EML", bundle id
   `org.qdvc.GTDEML`, executable `QDVCGTDEML`.
