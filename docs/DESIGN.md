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

The sidebar is one instance throughout, so it never jumps. Inbox and Sent
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
| `list` (ingest) | Workflow → Ingest Input | Ingest (`tray.and.arrow.down`) | ⇧⌘N | Get All New Mail |
| `alloc <dest>` | Message → Move To ▸ folder | Move To (menu) | ⌃⌘1 – ⌃⌘6 | Move to Favourite Mailbox |
| `alloc archive` | Message → Archive | Archive | ⌃⌘A | Archive |
| `close … with …` | Message → Close With… (sheet: pick the closing email) | Close With… | ⌥⌘K | — |
| `pin` / `unpin` | Message → Pin / Unpin | Pin | ⇧⌘L | Flag |
| `metadata set` | inline in the reading pane; Message → Edit Annotations… (⌘E) | — | ⌘E | — |
| `workflow_autofix` | Workflow → Review Date Stamps… (sheet listing every proposed stamp, one Apply button) | banner | — | — |
| `metadata_check` | Workflow → Check Metadata… (report sheet) | — | — | — |
| `view` | Message → Open in Mail / Quick Look | — | ⌘↓ / ⌘Y | Open Message |
| `search` | toolbar search field (all folders, including quoted text) | Search | ⌥⌘F | Mailbox Search |
| `stats` | the sidebar counts and the Dashboard | — | — | — |

Also:

- **Drag and drop:** dragging messages onto a Workflow folder in the sidebar
  is `alloc`, as dragging to a mailbox is in Mail. Dropping `.eml` files from
  Finder or Mail onto the window copies them into `01-input`.
- **Go to folder:** ⌘1 – ⌘6 select the six Workflow folders, as ⌘1… select
  favourite mailboxes in Mail. ⌘0 is the Dashboard, ⌘7 Performance and ⌘8
  the Calendar.
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
