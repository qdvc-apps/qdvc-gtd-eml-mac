# QDVC GTD EML for macOS — Design

Status: **approved; first implementation written.** The decisions taken on the
open questions are recorded in §9. Where the implementation differs from the
original proposal, this document has been updated to match it.

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

One window: a `NavigationSplitView` whose sidebar is the source list
(collapsible with ⌃⌘S / View → Hide Sidebar) and whose detail is either

1. the **message list** and the **reading pane** side by side (an
   `HSplitView`), as in Mail, or
2. the **Dashboard** or **Performance** page, using the full width.

The sidebar sections mirror the web UI's categories, relabelled with Mail's
vocabulary:

| Section | Entries | SF Symbol ideas |
| --- | --- | --- |
| Overview | Dashboard, Performance, Calendar | `square.grid.2x2`, `chart.xyaxis.line`, `calendar` |
| Workflow | Input, Triage, Actionable, Delegated, Reference, Archive (with counts) | `tray.and.arrow.down`, `tray`, `bolt`, `person.2`, `books.vertical`, `archivebox` |
| Smart Mailboxes | Due Date Set, No Due Date, Pinned, one per monitored hashtag | `calendar.badge.clock`, `calendar`, `pin`, `number` |
| Accounts | per own account: Inbox and Sent (only when accounts are configured) | `envelope`, `paperplane` |

The sidebar is one instance throughout, so it never jumps. Message windows
(§2.4) open beside it as tabs. Inbox and Sent
list every own account's mail and disclose one entry per account. Clicking a
Dashboard figure or project opens a temporary Results entry with the emails
it counted.

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
   the CLI allows free text), Flags, and Notes. Edit (⌘E) turns the card
   into a form in place; Save (Return) writes only the fields that changed,
   Cancel (Esc) discards.
4. **History** (only for an email in a history chain, §2.3).
5. **Workflow trail** (`ds_*` stamps) and the email's metrics, in a
   disclosure group.
6. **Message history:** the thread split into collapsible blocks, each with
   its own From / To / Date and attachments, nested quotes indented and
   collapsed, exactly as the web UI does.

Bodies are rendered as plain text (HTML parts converted to text), for the
same reason as the web UI: no remote content, no sender markup.

### 2.3 History chains

`close … with …` sets an email's next action to `Closed with <file>.eml`.
Used repeatedly, this links emails into a chain: A closed with B, B closed
with C, and so on; several emails can be closed with the same one, so a
chain can branch. An email in a chain shows a *History · n* pill, a
`clock.arrow.circlepath` glyph next to its subject in the list, and a
History card: a timeline of the whole chain, each email before the one that
closed it (emails closed by the same one in date order), ending with the
latest. "n of m" gives the email's place in it. Clicking an email selects
it, switching the list to its folder when the list on show does not include
it, as jumping to a message does in Mail. Where the chain branches, a row
names the email that closed it. A reference to a file that is no longer in
the workspace stays in the chain, marked as missing.

A reference is recognised when the next action starts with "Closed with"
(any case) followed by a name ending in `.eml`, as `close` writes it; text
after the name is allowed. It resolves as `find` would: the first folder in
workflow order, an exact name first and then a case-insensitive one.

### 2.4 Tabs and message windows

As in Mail with "Prefer tabs", an email can be opened in a **message
window**, which joins the tab group of the window it was opened from as a
native macOS tab. The viewer window (sidebar, list, reading pane) is the
first tab; a message tab shows just the email, with the same reading-pane
content and no toolbar items (the Message menu and context menus have the
actions). The tab bar has no "+" button, since there is no empty tab to
open. Dragging a message
tab out of the tab bar leaves it a standalone message window, since that is
what it is; Window → Merge All Windows puts it back. Only the viewer has a
sidebar, a list and a selection.

- **Opening:** Open in New Tab in the row's context menu and the Message
  menu; Open in New Tab, or ⌘-click, on an email in the History card (as a
  link in Safari). An email already open in a window is brought forward
  instead of being opened twice.
- **In a message tab,** clicking an email in the History card shows it in
  that tab; its context menu adds Show in Viewer, which switches to the
  viewer's tab and selects it in the list (it never opens a window). The Message menu acts on the tab's email, and sheets,
  alerts and in-place editing appear in the tab where they were asked for.
  A tab follows its email by file name, so it keeps showing it after a move.
- **Shortcuts:** ⌘W closes a tab (the system's Close), ⌘⇧T reopens the last
  closed message tab (Window → Reopen Closed Tab, as in Safari; ⌘⇧W stays
  Close Workspace), ⌘1 – ⌘9 select the first to ninth tab (Window → Select
  Tab), and ⌃⇥ / ⌃⇧⇥ move between tabs (system).
- Closing or changing the workspace closes its message windows. Message
  windows are not restored at the next launch.
- The list and reading pane are split by SwiftUI, not AppKit's split view
  (`HSplitView`), which ignores SwiftUI's safe area: with it, the tab bar
  cut across the tops of both when it appeared. The list's width is kept
  between launches.

## 3. Actions (the CLI, as Mail-style commands)

| CLI | Menu command | Toolbar | Shortcut | Mail precedent |
| --- | --- | --- | --- | --- |
| `list` (ingest) | Workflow → Ingest Input | Ingest (`tray.and.arrow.down`) | ⇧⌘N | Get All New Mail |
| `alloc <dest>` | Message → Move To ▸ folder | Move To (menu) | ⌃⌘1 – ⌃⌘6 | Move to Favourite Mailbox |
| `alloc archive` | Message → Archive | Archive | ⌃⌘A | Archive |
| `close … with …` | Message → Close With… (sheet: pick the closing email) | Close With… | ⌥⌘K | — |
| `pin` / `unpin` | Message → Pin / Unpin | Pin | ⇧⌘L | Flag |
| `metadata set` | inline in the reading pane; Message → Edit Annotations… (⌘E) | — | ⌘E | — |
| `metadata set next_action` (blank only) | Message → Set Next Action ▸ hashtag; drag to a hashtag mailbox | — | — | — |
| `workflow_autofix` | Workflow → Review Date Stamps… (sheet listing every proposed stamp, one Apply button) | banner | — | — |
| `metadata_check` | Workflow → Check Metadata… (report sheet) | — | — | — |
| `view` | Message → Open in Mail / Quick Look | — | ⌘↓ / ⌘Y | Open Message |
| `search` | toolbar search field (all folders, including quoted text) | Search | ⌥⌘F | Mailbox Search |
| `stats` | the sidebar counts and the Dashboard | — | — | — |

Also:

- **Drag and drop:** dragging messages onto a Workflow folder in the sidebar
  is `alloc`, as dragging to a mailbox is in Mail. Dragging them onto a
  hashtag Smart Mailbox makes the hashtag the next action (`metadata set
  next_action`) of each email whose next action is blank; an email that
  already has one is left alone, since the drop would otherwise overwrite
  it. The answer is given while hovering, as the HIG asks: a destination
  that would refuse every dragged email is not highlighted, shows the
  "operation not allowed" pointer, and says why in the window subtitle, so
  there is no alert to dismiss afterwards. A drop that some of the emails
  refuse is applied to the others, and the rest are listed in an alert, as
  for a partly refused move. The same hover check applies to folders.
  Message → Set Next Action ▸ (and the row's context menu) lists the
  monitored hashtags and does the same as the drop. Rows use the list's
  own dragging (`itemProvider`), so a click anywhere on a row selects it
  and a drag from anywhere on it carries the whole selection, as in Mail.
  Dropping `.eml` files from Finder or Mail onto the window copies them
  into `01-input`.
- **Go to folder:** View lists Dashboard, the six Workflow folders,
  Performance and Calendar. They have no shortcuts: ⌘1 – ⌘9 select tabs
  (§2.4).
- **Context menus** on rows repeat the Message menu.
- **No undo for moves.** Undoing an `alloc` would mean clearing a `ds_*`
  stamp, which nothing in the CLI ever does. Instead, moving is disabled
  when it would be refused (the context menu names the reason, e.g.
  "Triage — Already has ds_triage = 2026-09-30"), and there is nothing to
  confirm otherwise, which matches both Mail and the CLI.
- **Autofix banner:** when `plan_autofix` has outstanding fixes or blockers,
  a thin banner above the message list says so and offers Review…; the
  Performance view shows the same message instead of metrics, mirroring
  `generate_dashboard`'s refusal. Browsing and all other actions keep
  working.

## 4. Settings (⌘,)

- **General:** date format (the web UI's three), time zone for `.eml` dates
  (system by default), how to read quoted headers with no zone, which folders
  are *on radar* (the Smart Mailboxes cover only these, while Inbox and Sent
  always cover every folder; default Input, Triage, Actionable, Delegated), whether off-radar mail is
  dimmed, and whether to reopen the last workspace.
- **Workspace:** a read-only summary of the workspace's `workspace.yml`
  (`my_own_accounts`, `monitored_hashtags`, the age thresholds and
  `max_filename_chars`), with buttons to open it in a text editor and reload
  it. These settings belong to the workspace so that the CLI and the app
  agree; see [WORKSPACE_CONFIG_REQUEST.md](WORKSPACE_CONFIG_REQUEST.md).

The Settings window closes with ⌘W or its close button, like Settings
windows in Apple's apps. Esc does not close it: on macOS, Esc cancels a
modal dialog, sheet, menu or edit, and a Settings window has nothing to
cancel because every change applies at once.

Appearance (light/dark) follows the system, as native apps do; the web UI's
Warm/Neutral tone and font-stack overrides have no Mac equivalent and are
dropped.

## 5. Modules

See [MAINTENANCE.md §2](MAINTENANCE.md#2-modules) for the module list as
built.

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

The first version has the **open backlog** (headline figures and the current
pile by age) and **throughput** (arrivals, resolutions and the open backlog,
weekly or monthly), drawn with Swift Charts, with an account filter. Like
`generate_dashboard`, it shows figures only when 01-input is empty and the
date stamps are consistent; otherwise it explains what to do first. The KPI
table, box plots, percentiles, hit rates and the Sankey diagram are not
planned for now.

## 7a. Calendar view

A month grid (weeks start on Monday; ‹ › move between months, Today returns
to the current one, which is the default). Each day is shaded by the number
of distinct emails with at least one event that day, relative to the busiest
day of the month shown; days with no events are blank. Events are:

- each email's own `Date:` header, placed on a day in the Settings time zone;
- the dates of the messages quoted in its body, by the same rules as the
  reading pane (skipped when they name no real day);
- the five ds_* stamps in metadata.csv, as written.

`due_date` is a deadline, not an event, and is left out. Clicking a day lists
its emails (a Results entry in the sidebar), each labelled with what happened
to it that day. Below the grid, a small table counts the emails per kind of
event for the month.

## 8. Not planned

- `generate_dashboard` and `export masterdetail_yaml`: the app itself is the
  dashboard, and export is a batch job the CLI already does well.
- The mobile build.
- Any network access.

## 9. Decisions

1. **Settings** belong to the workspace, in `<working_directory>/workspace.yml`
   (read-only to the app). The gtd-eml team has been asked to read it too; see
   [WORKSPACE_CONFIG_REQUEST.md](WORKSPACE_CONFIG_REQUEST.md).
2. **Actions:** ingest, alloc, close, pin/unpin, metadata edit, workflow
   autofix and metadata check, as proposed.
3. **Performance:** open backlog and throughput only (§7).
4. **Ingest** runs only on the explicit command (⇧⌘N, toolbar, banner).
5. **Identity:** repository `qdvc-gtd-eml-mac`, bundle identifier
   `org.qdvc.gtdeml.mac`, app name "QDVC GTD EML".

One layout change was made while building: the window is a two-column split
(sidebar | content) whose content is either the message list and reading pane
side by side, or the Dashboard or Performance page. This keeps the sidebar
stable while letting the overview pages use the full width.
