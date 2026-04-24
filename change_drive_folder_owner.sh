#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  change_drive_folder_owner.sh --target EMAIL --folder FOLDER_ID_OR_URL [options]

Description:
  Change ownership of a Google Drive folder and its contents with standard GAM.

  By default, the script runs in preview mode and uses:
    gam user TARGET claim ownership FOLDER_ID preview filepath buildtree

  If you provide --source, the script switches to transfer mode and uses:
    gam user SOURCE transfer ownership FOLDER_ID TARGET preview filepath buildtree

  Preview mode is the default. Add --execute to apply the change.

Required arguments:
  --target EMAIL          New owner email address.
  --folder VALUE          Folder ID, full Drive folder URL, or id:VALUE.

Options:
  --source EMAIL          Current owner. Enables GAM transfer mode instead of claim mode.
  --gam PATH              GAM executable to use. Defaults to $GAM_CMD or `gam`.
  --execute               Apply the ownership change. Without this flag, preview only.
  --include-trashed       Include trashed files.
  --retain-role ROLE      Claim mode only. One of: reader, commenter, writer, editor, none.
                          If omitted, GAM keeps the prior owner as writer.
  --path-delimiter CHAR   Preview mode only. Defaults to /.
  --verbose               Print the resolved GAM command before running it.
  -h, --help              Show this help text.

Notes:
  - Ownership changes do not apply to Shared Drives.
  - Claim mode is the simpler interface because you only need the target user.
  - Transfer mode is more explicit when you know the current owner of the folder.
  - The safest folder identifier is the Drive folder ID, e.g. the part after /folders/ in:
      https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz

Examples:
  Preview with the target user claiming ownership:
    ./change_drive_folder_owner.sh \
      --target new.owner@example.com \
      --folder https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz

  Execute the change:
    ./change_drive_folder_owner.sh \
      --target new.owner@example.com \
      --folder 1AbCdEfGhIjKlMnOpQrStUvWxYz \
      --execute

  Use explicit source-owner transfer mode:
    ./change_drive_folder_owner.sh \
      --source old.owner@example.com \
      --target new.owner@example.com \
      --folder 1AbCdEfGhIjKlMnOpQrStUvWxYz \
      --execute
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2-}"
  [[ -n "$value" ]] || die "Missing value for ${option}"
}

is_valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

extract_drive_id() {
  local input="$1"
  local candidate="${input#id:}"
  local folder_regex='/folders/([A-Za-z0-9_-]+)'
  local query_regex='[?&]id=([A-Za-z0-9_-]+)'
  local document_regex='/d/([A-Za-z0-9_-]+)'

  if [[ "$candidate" =~ ^https?:// ]]; then
    if [[ "$candidate" =~ $folder_regex ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
    if [[ "$candidate" =~ $query_regex ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
    if [[ "$candidate" =~ $document_regex ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
    die "Could not extract a Drive file ID from: $input"
  fi

  if [[ "$candidate" =~ ^[A-Za-z0-9_-]{10,}$ ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  die "Folder must be a Drive folder ID, full URL, or id:VALUE"
}

print_command() {
  local arg
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}

resolve_gam_bin() {
  local requested="$1"
  local resolved=""
  local candidate
  local -a fallback_paths=(
    "$HOME/bin/gam"
    "$HOME/bin/gam7/gam"
    "/opt/homebrew/bin/gam"
    "/usr/local/bin/gam"
  )

  if [[ "$requested" == */* ]]; then
    [[ -x "$requested" ]] || die "GAM executable is not runnable: $requested"
    printf '%s\n' "$requested"
    return 0
  fi

  resolved="$(command -v "$requested" 2>/dev/null || true)"
  if [[ -n "$resolved" && -x "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  for candidate in "${fallback_paths[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "GAM executable not found. '$requested' is not on PATH for this Bash script. If GAM is configured as a shell alias, pass --gam /full/path/to/gam or set GAM_CMD=/full/path/to/gam."
}

target=""
source=""
folder_input=""
gam_bin="${GAM_CMD:-gam}"
execute=false
include_trashed=false
verbose=false
retain_role=""
path_delimiter="/"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      require_value "$1" "${2-}"
      target="$2"
      shift 2
      ;;
    --source)
      require_value "$1" "${2-}"
      source="$2"
      shift 2
      ;;
    --folder)
      require_value "$1" "${2-}"
      folder_input="$2"
      shift 2
      ;;
    --gam)
      require_value "$1" "${2-}"
      gam_bin="$2"
      shift 2
      ;;
    --execute)
      execute=true
      shift
      ;;
    --include-trashed)
      include_trashed=true
      shift
      ;;
    --retain-role)
      require_value "$1" "${2-}"
      retain_role="$2"
      shift 2
      ;;
    --path-delimiter)
      require_value "$1" "${2-}"
      path_delimiter="$2"
      shift 2
      ;;
    --verbose)
      verbose=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$target" ]] || die "Missing required argument: --target"
[[ -n "$folder_input" ]] || die "Missing required argument: --folder"

is_valid_email "$target" || die "Invalid --target email address: $target"
if [[ -n "$source" ]]; then
  is_valid_email "$source" || die "Invalid --source email address: $source"
fi

if [[ -n "$retain_role" && -n "$source" ]]; then
  die "--retain-role is only supported in claim mode; remove --source or remove --retain-role"
fi

if [[ -n "$retain_role" ]]; then
  case "$retain_role" in
    reader|commenter|writer|editor|none)
      ;;
    *)
      die "--retain-role must be one of: reader, commenter, writer, editor, none"
      ;;
  esac
fi

[[ -n "$path_delimiter" ]] || die "--path-delimiter cannot be empty"

gam_bin="$(resolve_gam_bin "$gam_bin")"

folder_id="$(extract_drive_id "$folder_input")"

declare -a cmd

if [[ -n "$source" ]]; then
  cmd=("$gam_bin" "user" "$source" "transfer" "ownership" "$folder_id" "$target")
else
  cmd=("$gam_bin" "user" "$target" "claim" "ownership" "$folder_id")
  if [[ -n "$retain_role" ]]; then
    if [[ "$retain_role" == "writer" ]]; then
      cmd+=("keepuser")
    else
      cmd+=("retainrole" "$retain_role")
    fi
  fi
fi

if [[ "$include_trashed" == true ]]; then
  cmd+=("includetrashed")
fi

if [[ "$execute" == false ]]; then
  cmd+=("preview" "filepath")
  if [[ -n "$path_delimiter" ]]; then
    cmd+=("pathdelimiter" "$path_delimiter")
  fi
  cmd+=("buildtree")
fi

if [[ "$verbose" == true || "$execute" == false ]]; then
  if [[ -n "$source" ]]; then
    printf 'Mode: transfer\n'
  else
    printf 'Mode: claim\n'
  fi
  printf 'Folder ID: %s\n' "$folder_id"
  printf 'Command: '
  print_command "${cmd[@]}"
fi

exec "${cmd[@]}"
