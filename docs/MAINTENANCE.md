# QDVC GTD EML for macOS — Maintenance Guide

This guide is for whoever maintains the app next. It explains how the code is
laid out, which behaviour is shared with the
[qdvc-gtd-eml](https://github.com/qdvc-apps/qdvc-gtd-eml) command-line tool and
must not drift, and how that is tested.

The one rule that matters most: **the workspace is the contract.** The app and
the CLI read and write the same six folders and the same `metadata.csv`, byte
for byte. Any change that alters a filename the app generates, or a byte of
`metadata.csv` it writes, is a bug unless the CLI changes the same way.

## 1. Layout

```
Package.swift                 SwiftPM manifest (no Xcode project)
Sources/GTDCore/              the model: a port of gtd_modules (Foundation + Yams)
Sources/QDVCGTDEML/           the SwiftUI/AppKit app
Tests/GTDCoreTests/           parity + unit tests; Fixtures/parity.json
tools/make_fixtures.py        regenerates the parity fixture from the Python code
tools/make_icon.py            regenerates Resources/AppIcon.{svg,icns}
scripts/build-app.sh          builds and ad-hoc signs "QDVC GTD EML.app"
Resources/Info.plist          bundle id org.qdvc.gtdeml.mac
sample-workspace/             a small workspace made by the Python edition
docs/                         DESIGN, FILE_FORMAT, this guide, the team request
```

`GTDCore` has no AppKit or SwiftUI imports and builds on Linux; the app target
is declared on macOS only (see `Package.swift`). Yams (from 5.1.0) is the only
dependency, used to read `workspace.yml`. Commit `Package.resolved` after the
first build so everyone gets the same Yams.

### 1.1 App icon

`tools/make_icon.py` writes `Resources/AppIcon.svg` and `Resources/AppIcon.icns`
(needs `rsvg-convert`; `brew install librsvg`). The design is the family's
frosted-glass envelope, sealed with a green check mark, in a sage palette.
`--preview` also writes `build/icon-preview.png`.

## 2. Modules

`GTDCore`:

| File | Responsibility | Python origin |
| --- | --- | --- |
| `TextSupport.swift` | Python-compatible string helpers (code-point semantics), regex wrapper, `Day` (a `datetime.date`), atomic writes | — |
| `Charsets.swift` | `bytes.decode(charset, errors)` for mail charsets | Python codecs |
| `MIME.swift` | the feed parser, headers, parameters (RFC 2231), QP/base64, RFC 2047 `decode_header` + `make_header` | `email` (compat32) |
| `AddressesAndDates.swift` | `getaddresses` (strict), `parsedate_to_datetime` | `email.utils`, `email._parseaddr` |
| `EmailUtil.swift` | subject, body text, HTML to text, attachments, correspondents, message refs, own-account matching; `ParsedEmail` | `emailutil.py` |
| `Thread.swift` | split a body into its quoted history; quoted-header dates | `thread.py` |
| `Naming.swift` | slugs, filenames, `-N` collisions before a protected ref | `naming.py` |
| `Config.swift` | `Folder`, `OwnAccount`, `WorkspaceConfig` (workspace.yml), small rules | `config.py`, `report.py`, `site.py` |
| `CSV.swift` | Python's `csv` (excel dialect) | `csv` |
| `Metadata.swift` | load, sync, render `metadata.csv` | `metadata.py` |
| `Workspace.swift` | folders, find, ingest, alloc, close, pin/unpin, set, metadata check, autofix apply, adding files | `fs.py`, `ingest.py`, `commands/*.py` |
| `Metrics.swift` | autofix planning, status and `ttS`/`Td`/`Wd`/`tttR`, backlog, histogram, flow series | `metrics.py`, `dashboard.py` |
| `Records.swift` | `EmailRecord`, Dashboard `Overview`, list date buckets, the cached loader | `site.py` |

The app (`QDVCGTDEML`): `GTDApp` (scenes), `AppModel` (all state and actions,
`@Observable`), `Commands` (menus and shortcuts), `ContentView` (window,
toolbar, banners, sheets, alerts, welcome screen), `SidebarView`,
`MessageListView`, `ReadingPane` (pills, annotations card, workflow trail,
thread), `DashboardView`, `PerformanceView` (Swift Charts), `Sheets` (Close
With, Review Date Stamps, Check Metadata), `SettingsView`, `Prefs`,
`DateFormatting`, `Platform`.

Every workflow action goes through `Workspace` and is followed by a reload.
Parses are cached by (filename, size, modification date), so a reload after
a move re-reads only `metadata.csv`. The app also reloads when it becomes
active, to pick up changes made by the CLI.

## 3. Behaviour that must be preserved

These are what the parity fixture checks; see `tools/make_fixtures.py` for
the cases.

- **Reading `.eml` files** as Python does: universal newlines, compat32
  header values (folds kept), raw 8-bit headers replaced by U+FFFD per byte
  and not RFC 2047-decoded, any RFC 2047 failure returning the raw header,
  lenient base64 that stops at a completed pad, `a2b_qp` quirks, the payload
  losing the newline before a boundary, a multipart with no start boundary
  being a leaf.
- **Dates:** a naive or `-0000` date is UTC; an unusable or missing Date is
  "now" (UTC). The filename date is the header's own calendar day in its own
  offset; the age is today (UTC) minus that day.
- **Filenames:** `yyyy-mm-dd-slug[-ref-<ref>].eml` within
  `max_filename_chars`, the ref never truncated, `-2`, `-3`… inserted before
  the ref. Existing names across *all six* folders (including 01-input)
  count as taken.
- **Message refs:** the first match in the raw body (plain part, else raw
  HTML).
- **metadata.csv:** the twelve columns in order, `\r\n`, minimal quoting,
  rows sorted by filename in code-point order, one row per `.eml` in any
  folder; ingest seeds `ds_triage` (today, local) and `message_ref`.
- **Refusals** with the CLI's wording: `alloc` never overwrites a set stamp;
  `close` needs the other email, and refuses an archived email or a set
  `ds_archive`; `ds_*` are never user-editable; autofix refuses while
  01-input has files and never runs with blockers.
- **Flags:** pin/unpin split on whitespace and rejoin with single spaces; the
  display parses commas and whitespace, lower-cased.
- **Performance figures** exclude weird emails; backlog ages use today
  (local) minus the filename date.

## 4. Deliberate differences from the Python edition

- **Settings** come from `<workspace>/workspace.yml`, read-only, rather than
  the CLI's `config.yml`, which the app cannot see. See
  [WORKSPACE_CONFIG_REQUEST.md](WORKSPACE_CONFIG_REQUEST.md).
- **Ingest never runs by itself.** `gtd list` ingests on every run; the app
  only on the Ingest command.
- **Actions on 01-input files** other than ingest are disabled: moving would
  skip the rename, and annotations would be lost when ingest renames the
  file. (The CLI allows `alloc` from 01-input.)
- **Batching:** the app writes several fields at once (Save, Close With,
  Apply All) in one `metadata.csv` write; the bytes are the same as the CLI's
  sequence of writes.
- **Charsets** beyond UTF-8, ASCII, Latin-1, Windows-1252 and UTF-16 go
  through Foundation, which cannot replace invalid bytes one by one; invalid
  text in those charsets falls back to lenient UTF-8.
- **Rare parser paths** are simplified: `message/delivery-status` is kept as
  text, uuencoded parts are left encoded, and a BOM before the CSV header is
  ignored (Python would fail to find the first column).
- **Performance** shows only the open backlog and throughput sections.
- **Dates in the list** are Mail-style (time today, Yesterday, weekday,
  then a compact date); the headings follow the design's buckets.

## 5. Tests

```
swift test
```

`ParityTests` replays `Fixtures/parity.json`: header decoding, date parsing,
slugs and filenames, HTML stripping, thread splitting, 21 whole emails (every
parsed field plus the filenames at 60 and 40 characters), autofix plans,
metrics, backlog and flow series, and a scripted CLI session (ingest, alloc
including refusals, metadata set, pin/unpin, close, metadata check, autofix)
compared file-by-file and byte-for-byte with `metadata.csv`. `CoreTests`
covers pieces the fixture does not (config parsing, dates, buckets,
import/load).

To regenerate the fixture after a change in the Python edition:

```
python3 tools/make_fixtures.py --python-repo ../qdvc-gtd-eml
```

Then run the tests; any difference is either a CLI change to port or a bug.
To add a case, add an input to the lists at the top of the script.

`sample-workspace/` was produced by the Python edition's own commands, so it
is also a quick manual check: open it, and the app should agree with
`gtd list` on it.

## 6. Roadmap

- The rest of the performance dashboard (KPI table, box plots, percentiles,
  hit rates, Sankey) if wanted.
- A CI workflow running `swift test` on Linux and macOS.
- Undo for annotation edits (moves stay un-undoable, as in the CLI).
