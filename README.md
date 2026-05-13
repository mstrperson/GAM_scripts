# GAM Scripts

This repository contains a growing set of small tools for managing our Google Workspace domain quickly and consistently with the standard `GAM` CLI.

The goal is to keep common admin operations easy to run, easier to review, and less error-prone than typing long `gam` commands by hand.

## Requirements

- Standard `GAM` CLI installed and authenticated
- Appropriate Google Workspace admin permissions for the actions being performed
- Shell access on a machine where `gam` is available in `PATH`, or explicit script configuration that points to the `gam` binary

## Script Catalog

This section is the living index for the repository. Each time a new script is added, this list should be updated with:

- The script name
- A short description of what it does
- Any important notes or limitations

| Script | Purpose | Notes |
| --- | --- | --- |
| `change_drive_folder_owner.sh` | Changes ownership of a Google Drive folder to a target user. Supports preview mode by default, can run in claim or transfer mode, and can verify resulting ownership after execution. | Accepts a Drive folder ID or full folder URL. Uses single-folder mode by default; add `--recurse` for descendants. Intended for My Drive content, not Shared Drives. |
| `transfer_user_drive.sh` | Transfers ownership of a user's entire My Drive contents to another user. Designed for offboarding. Supports a two-phase transfer (ownership-in-place for already-shared files, then move for the rest), shortcuts for externally-owned files, trashed file handling, and a Markdown audit report. | Preview mode by default; add `--execute` to apply. Trashed files are included by default for complete offboarding; use `--exclude-trashed` to opt out. Does not affect Shared Drives. |
| `manage_gmail_delegates.sh` | Adds or removes Gmail mailbox delegation for one or more delegate accounts against a target mailbox. Defaults to dry-run output before execution. | Accepts repeated delegates, comma-separated lists, or a file of delegate addresses. |

## Current Scripts

### `change_drive_folder_owner.sh`

Changes ownership of a Google Drive folder to a new owner using standard `GAM`.

Key behavior:

- Defaults to preview mode so the command can be reviewed before execution
- Accepts either a folder ID or a full Google Drive folder URL
- Processes only the selected folder by default; add `--recurse` to include descendants
- Uses `claim ownership` when only the target user is supplied
- Uses `transfer ownership` when the current owner is explicitly supplied
- Verifies the resulting ownership after `--execute` unless `--no-verify` is supplied

Example:

```bash
./change_drive_folder_owner.sh \
  --target new.owner@example.com \
  --folder https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz
```

### `transfer_user_drive.sh`

Transfers ownership of a user's entire My Drive contents to another user using standard `GAM`. Designed for offboarding a departing user.

#### How the transfer works

The script runs in up to three sequential phases:

1. **Permission scan** (`--scan-access`): Queries the source's Drive for owned files the target can already access. Ownership of those files is transferred in place — they are not moved to the destination folder. Because they are no longer source-owned after this step, the main transfer naturally skips them.

2. **Shortcut creation** (`--create-shortcuts`): Scans for files in the source's Drive that are owned by external accounts (outside your Google Workspace domain). Creates a Drive shortcut for each one, owned by the source, so the shortcuts are carried along in the main transfer. The target user will have visibility into these files but may need to request access from the external owners directly.

3. **Main transfer**: Runs `gam user SOURCE transfer drive TARGET`, which transfers ownership of all remaining source-owned files. Use `--dest-folder` or `--dest-folder-name` to land these files in a specific folder in the target's Drive rather than at the root.

All three phases are optional. Running without any of these flags performs a straightforward full-drive transfer.

#### Trashed files

`transfer drive` handles trashed files natively. The pre-transfer scans (`--scan-access`) and the post-transfer verification also include trashed files by default, so verification produces a genuine all-clear — not just "clean except trash."

Use `--exclude-trashed` to restrict scans and verification to non-trashed files only. This is rarely the right choice for offboarding, but may be appropriate if you are doing a targeted transfer and do not want the source's trash included in the audit.

#### "Not Processed" messages

During the transfer, GAM may emit lines like:

```
User: source@domain, Drive File: filename, Not Processed: Service not applicable for this address: user@external.com
```

The script automatically explains these at the end of the run. Common reasons:

- **Service not applicable for this address** — the file is owned by an external or personal Google account; ownership cannot be transferred via the Workspace API. Use `--create-shortcuts` to preserve a reference to these files.
- **Drive Service/App not enabled** — the file's owner is a suspended or disabled domain account. These files are not owned by the source user and cannot be transferred by this script. Use the Google Workspace Admin Console to locate the disabled account's Drive and transfer it separately before the account is permanently deleted.
- **User not found** — the file's owner account no longer exists in the domain.
- **Permission not found** — the source user's access to the file could not be verified at transfer time.

#### Audit report

`--report [FILE]` writes a Markdown file summarising the entire run: metadata, counts, the full list of files with in-place ownership transfers, shortcuts created, skipped files with reasons, and the verification result. The report is written via a shell trap and is produced even if the script is interrupted or exits with an error, making it a reliable audit trail.

If `FILE` is omitted, the report is auto-named in the current directory.

#### Key behavior

- Preview mode by default — no changes are made without `--execute`
- Only source-owned files are ever touched; files in the source's My Drive owned by others are ignored
- `--scan-access` detects explicit sharing only; access via Google Groups or "anyone with the link" is not detected
- Does not affect Shared Drives
- For large drives, run inside `screen` or `tmux` to prevent a disconnection from interrupting the transfer mid-run

#### Recommended full offboarding dry run

```bash
./transfer_user_drive.sh \
  --source departing.user@example.com \
  --target receiving.user@example.com \
  --dest-folder-name "Departing User Files" \
  --scan-access \
  --create-shortcuts \

  --report offboarding_preview.md
```

Review the generated report, then re-run with `--execute` to apply.

#### Examples

Execute a full offboarding transfer:

```bash
./transfer_user_drive.sh \
  --source departing.user@example.com \
  --target receiving.user@example.com \
  --dest-folder-name "Departing User Files" \
  --scan-access \
  --create-shortcuts \

  --report offboarding_$(date +%Y%m%d).md \
  --execute
```

Transfer into an existing folder:

```bash
./transfer_user_drive.sh \
  --source departing.user@example.com \
  --target receiving.user@example.com \
  --dest-folder https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz \
  --execute
```

Verify a completed transfer:

```bash
./transfer_user_drive.sh \
  --source departing.user@example.com \
  --target receiving.user@example.com \

  --verify-only
```

### `manage_gmail_delegates.sh`

Adds or removes Gmail delegation on a target mailbox for one or more delegate users using standard `GAM`.

Key behavior:

- Defaults to dry-run mode so the final `gam` command can be reviewed first
- Accepts delegates through repeated flags, a comma-separated list, or a text file
- Supports both add and remove operations with the same interface
- De-duplicates delegate addresses before building the final command

Example:

```bash
./manage_gmail_delegates.sh \
  --mailbox shared.inbox@example.com \
  --delegate alice@example.com \
  --delegate bob@example.com
```

## Maintenance

When a new script is added to this repository:

1. Add it to the `Script Catalog` table.
2. Add a short subsection under `Current Scripts` if the script needs more context.
3. Keep descriptions concise and operational so someone scanning the README can quickly find the right tool.
