# Request to the qdvc-gtd-eml maintainers: move workspace settings into the workspace

**To:** the qdvc-gtd-eml team
**From:** the QDVC GTD EML for macOS project
**Subject:** Please read five settings from `<working_directory>/workspace.yml`

Hello,

We are building a native macOS app that opens a gtd-eml workspace directly and
performs the core workflow actions (ingest, `alloc`, `close`, `pin`/`unpin`,
`metadata set`, `workflow_autofix`). The app is pointed at the workspace
folder, so it cannot see `config.yml`, which lives next to `gtd.py`. Five of
the settings in `config.yml` describe the *workspace* rather than the
*installation*, and the app needs them to behave exactly as the CLI does. In
particular, `max_filename_chars` changes the filenames that ingestion
produces, so the two tools must read the same value.

Please make the following change.

## 1. The new file

A new, optional YAML file at the root of the working directory, next to
`metadata.csv`:

```
<working_directory>/
    01-input/ … 06-archive/
    metadata.csv
    workspace.yml        <- new
```

It holds exactly these keys, with the same meaning, types, defaults and
normalisation as today (`config.normalise_accounts`,
`config.normalise_hashtags`):

| Key | Default |
| --- | --- |
| `my_own_accounts` | `[]` |
| `monitored_hashtags` | `[]` |
| `green_max_days` | `2` |
| `yellow_max_days` | `14` |
| `max_filename_chars` | `60` |

Example:

```yaml
# workspace.yml — settings that belong to this workspace, shared by every
# tool that opens it (the gtd CLI and the macOS app).
max_filename_chars: 60
green_max_days: 2
yellow_max_days: 14
my_own_accounts:
  - email_address: james.smith@example.com
    display_name: "Work account"
    colour: yellow
monitored_hashtags:
  - "#urgent"
  - "#family"
```

Every key is optional; a missing file means "all defaults". Unknown keys
should be ignored (so either tool can add a key later without breaking the
other).

## 2. What stays in `config.yml`

These are properties of the installation or of the terminal, and stay where
they are: `working_directory`, `archive_report_n`, `max_subject_chars`,
`force_colour`, `plotly_js_path`, `cli_command`.

## 3. Loading rules for the CLI

In `config.load_config()`:

1. Load `config.yml` exactly as now (defaults, then file values).
2. Resolve `working_directory`.
3. If `<working_directory>/workspace.yml` exists, load it with
   `yaml.safe_load` and, for each of the five keys above whose value is not
   `None`, **overwrite** the value from step 1.
4. If any of the five keys is still present in `config.yml` *and*
   `workspace.yml` does not define it, keep using the `config.yml` value but
   print one warning line to stderr, for example:
   `warning: 'my_own_accounts' in config.yml is deprecated; move it to
   <working_directory>/workspace.yml`.
   This keeps existing installations working during the transition.
5. Normalise `my_own_accounts` and `monitored_hashtags` afterwards, as now.

A `workspace.yml` that is not a YAML mapping (or fails to parse) should be a
clear error naming the file, not a silent fallback, because a silently
ignored `max_filename_chars` would produce different filenames from the Mac
app.

## 4. One-off migration of an existing installation

For each installation:

1. Open `config.yml` and find its `working_directory`.
2. Create `<working_directory>/workspace.yml`.
3. Cut these keys (with their values, exactly as written) from `config.yml`
   and paste them into `workspace.yml`: `my_own_accounts`,
   `monitored_hashtags`, `green_max_days`, `yellow_max_days`,
   `max_filename_chars`. Omit any key that was not set; its default applies.
4. Run `gtd.py list` and `gtd.py generate_dashboard`: the report colours, the
   own-account labels, the Inbox/Sent views and the hashtag views should be
   unchanged, and no deprecation warning should be printed.
5. If the working directory is tracked with git or synced, commit or sync
   `workspace.yml` like the rest of the workspace.

## 5. Files to update in the repository

- `gtd_modules/config.py` — the loading rules above, plus a
  `WORKSPACE_CONFIG_FILE = "workspace.yml"` constant and a
  `WORKSPACE_KEYS` list of the five keys.
- `README.md` and `MAINTENANCE.md` §5 — document `workspace.yml`, and move
  the five keys out of the `config.yml` tables and examples.
- `misc/_gtd` — no change needed (it reads only `working_directory`).

Nothing else about the workspace format changes: the six folders, the
filenames, and `metadata.csv` stay exactly as they are.

## 6. How the macOS app will use it

The Mac app reads `workspace.yml` (read-only) with the same defaults and
normalisation. It never writes the file; to change a setting, users edit it
in a text editor, and the app offers to open it (and reloads it on Refresh).
Until your change ships, the app simply sees the defaults, so please land it
before anyone relies on account labels or a non-default `max_filename_chars`
in the Mac app.

Thank you!
