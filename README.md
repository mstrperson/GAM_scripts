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
| `change_drive_folder_owner.sh` | Changes ownership of a Google Drive folder and its contents to a target user. Supports preview mode by default and can run in claim or transfer mode. | Accepts a Drive folder ID or full folder URL. Intended for My Drive content, not Shared Drives. |
| `manage_gmail_delegates.sh` | Adds or removes Gmail mailbox delegation for one or more delegate accounts against a target mailbox. Defaults to dry-run output before execution. | Accepts repeated delegates, comma-separated lists, or a file of delegate addresses. |

## Current Scripts

### `change_drive_folder_owner.sh`

Changes ownership of a Google Drive folder and the items contained within it to a new owner using standard `GAM`.

Key behavior:

- Defaults to preview mode so the command can be reviewed before execution
- Accepts either a folder ID or a full Google Drive folder URL
- Uses `claim ownership` when only the target user is supplied
- Uses `transfer ownership` when the current owner is explicitly supplied

Example:

```bash
./change_drive_folder_owner.sh \
  --target new.owner@example.com \
  --folder https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz
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
