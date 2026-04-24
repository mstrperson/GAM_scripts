#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  change_drive_folder_owner.sh --target EMAIL --folder FOLDER_ID_OR_URL [options]
  change_drive_folder_owner.sh --target EMAIL --folder FOLDER_ID_OR_URL --verify-only [options]

Description:
  Change ownership of a Google Drive folder with standard GAM.

  By default, the script runs in preview mode and uses:
    gam user TARGET claim ownership FOLDER_ID norecursion preview filepath

  If you provide --source, the script switches to transfer mode and uses:
    gam user SOURCE transfer ownership FOLDER_ID TARGET norecursion preview filepath

  Preview mode is the default. Preview enumerates the folder tree and reports what
  would be transferred, but it does not change ownership. Add --execute to apply
  the change.

  Recursion is opt-in. By default, only the selected folder itself is processed.
  Add --recurse to include descendant files and folders.

  By default, an executed transfer is followed by a verification pass that checks
  whether the target user is now the owner of all items in the selected folder
  tree. Use --no-verify to skip that check, or --verify-only to run only the
  verification step without changing ownership.

Required arguments:
  --target EMAIL          New owner email address.
  --folder VALUE          Folder ID, full Drive folder URL, or id:VALUE.

Options:
  --source EMAIL          Current owner. Enables GAM transfer mode instead of claim mode.
  --gam PATH              GAM executable to use. Defaults to $GAM_CMD or `gam`.
  --execute               Apply the ownership change. Without this flag, preview only.
  --recurse               Include descendant files and folders. Default is folder only.
  --verify-only           Verify current ownership under the folder without making changes.
  --no-verify             Skip post-execution verification.
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
  - Recursion is disabled by default; use --recurse to process the full tree.
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

  Execute recursively:
    ./change_drive_folder_owner.sh \
      --target new.owner@example.com \
      --folder 1AbCdEfGhIjKlMnOpQrStUvWxYz \
      --recurse \
      --execute

  Verify current ownership without making changes:
    ./change_drive_folder_owner.sh \
      --target new.owner@example.com \
      --folder 1AbCdEfGhIjKlMnOpQrStUvWxYz \
      --verify-only

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

verify_ownership() {
  local verify_csv=""
  local mismatch_csv=""
  local awk_status=0
  local total_lines=0
  local total_items=0
  local mismatch_lines=0
  local mismatch_count=0
  local -a verify_cmd=(
    "$gam_bin"
    "config" "csv_output_header_filter" "Owner,id,owners.0.emailAddress"
    "redirect" "csv"
    ""
    "user" "$target"
    "print" "filelist"
    "select" "$folder_id"
    "showownedby" "any"
    "fields" "id,owners.emailaddress"
  )

  verify_csv="$(mktemp)"
  mismatch_csv="$(mktemp)"
  verify_cmd[6]="$verify_csv"

  if [[ "$include_trashed" == false ]]; then
    verify_cmd+=("excludetrashed")
  fi

  if [[ "$recurse" == false ]]; then
    verify_cmd+=("norecursion")
  fi

  if [[ "$verbose" == true ]]; then
    printf 'Verify command: '
    print_command "${verify_cmd[@]}"
  fi

  "${verify_cmd[@]}"

  if [[ ! -s "$verify_csv" ]]; then
    rm -f "$verify_csv" "$mismatch_csv"
    die "Verification failed: GAM returned no ownership data for folder ID $folder_id"
  fi

  set +e
  awk -F, -v target_owner="$target" '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        if ($i == "owners.0.emailAddress") {
          owner_col = i
        }
      }
      if (!owner_col) {
        exit 2
      }
      print
      next
    }
    $owner_col != target_owner { print }
  ' "$verify_csv" > "$mismatch_csv"
  awk_status=$?
  set -e

  if [[ "$awk_status" -ne 0 ]]; then
    rm -f "$verify_csv" "$mismatch_csv"
    die "Verification failed: could not locate owners.0.emailAddress in GAM CSV output"
  fi

  total_lines="$(wc -l < "$verify_csv")"
  if [[ "$total_lines" -gt 0 ]]; then
    total_items=$((total_lines - 1))
  fi

  mismatch_lines="$(wc -l < "$mismatch_csv")"
  if [[ "$mismatch_lines" -gt 0 ]]; then
    mismatch_count=$((mismatch_lines - 1))
  fi

  if [[ "$total_items" -le 0 ]]; then
    rm -f "$verify_csv" "$mismatch_csv"
    die "Verification failed: no items were returned for folder ID $folder_id"
  fi

  if [[ "$mismatch_count" -gt 0 ]]; then
    printf 'Verification failed: %s item(s) in the folder tree are not owned by %s.\n' "$mismatch_count" "$target" >&2
    printf 'Ownership mismatches (Owner,id,owners.0.emailAddress):\n' >&2
    sed -n '1,21p' "$mismatch_csv" >&2
    if [[ "$mismatch_count" -gt 20 ]]; then
      printf 'Showing first 20 mismatches.\n' >&2
    fi
    rm -f "$verify_csv" "$mismatch_csv"
    exit 1
  fi

  printf 'Verification successful: %s item(s) in the folder tree are owned by %s.\n' "$total_items" "$target"
  rm -f "$verify_csv" "$mismatch_csv"
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
verify_only=false
verify=true
recurse=false
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
    --recurse)
      recurse=true
      shift
      ;;
    --verify-only)
      verify_only=true
      shift
      ;;
    --no-verify)
      verify=false
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

if [[ "$execute" == true && "$verify_only" == true ]]; then
  die "--execute and --verify-only cannot be used together"
fi

gam_bin="$(resolve_gam_bin "$gam_bin")"

folder_id="$(extract_drive_id "$folder_input")"

if [[ "$verify_only" == true ]]; then
  printf 'Mode: verify-only\n'
  printf 'Folder ID: %s\n' "$folder_id"
  printf 'Recursive: %s\n' "$recurse"
  verify_ownership
  exit 0
fi

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

if [[ "$recurse" == false ]]; then
  cmd+=("norecursion")
fi

if [[ "$include_trashed" == true ]]; then
  cmd+=("includetrashed")
fi

if [[ "$execute" == false ]]; then
  cmd+=("preview" "filepath")
  if [[ -n "$path_delimiter" ]]; then
    cmd+=("pathdelimiter" "$path_delimiter")
  fi
  if [[ "$recurse" == true ]]; then
    cmd+=("buildtree")
  fi
fi

if [[ "$verbose" == true || "$execute" == false ]]; then
  if [[ -n "$source" ]]; then
    printf 'Mode: transfer\n'
  else
    printf 'Mode: claim\n'
  fi
  printf 'Folder ID: %s\n' "$folder_id"
  printf 'Recursive: %s\n' "$recurse"
  printf 'Command: '
  print_command "${cmd[@]}"
fi

if [[ "$execute" == false ]]; then
  printf 'Preview only: no ownership changes will be made. Re-run with --execute to apply.\n'
  "${cmd[@]}"
  printf 'Preview complete. No ownership was changed.\n'
  exit 0
fi

"${cmd[@]}"

if [[ "$verify" == true ]]; then
  verify_ownership
else
  printf 'Execution complete. Verification skipped.\n'
fi
