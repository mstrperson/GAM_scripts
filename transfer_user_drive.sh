#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  transfer_user_drive.sh --source EMAIL --target EMAIL [options]
  transfer_user_drive.sh --source EMAIL --target EMAIL --verify-only [options]

Description:
  Transfer ownership of a Google Drive user's entire My Drive contents to another user.

  Uses: gam user SOURCE transfer drive TARGET [targetfolderid FOLDER_ID]

  Only files and folders owned by the source user are transferred. Files that appear
  in the source's My Drive but are owned by someone else are never touched.

  Use --scan-access to check sharing permissions before the transfer runs. Files
  that the target user can already access (explicitly shared with them) have their
  ownership transferred in place and are not moved to the destination folder. The
  main transfer then processes only the files the target cannot yet reach. In
  preview mode, --scan-access reports the counts without making any changes.

  Use --create-shortcuts to create Drive shortcuts for any externally-owned files
  found in the source's My Drive before the transfer runs. The shortcuts are owned
  by the source user and are therefore included in the transfer, giving the target
  user a reference to those files in the destination folder. In preview mode,
  --create-shortcuts reports how many external files were found without creating
  anything.

  Preview mode is the default. Preview enumerates the files that would be transferred
  but does not change ownership. Add --execute to apply the transfer.

  Use --dest-folder to place transferred content inside a specific folder in the target
  user's Drive rather than at the root of their My Drive. The folder must already exist
  and the target user must own it.

  After an executed transfer, a verification pass checks whether the source user
  has no remaining owned files in My Drive. Use --no-verify to skip that check, or
  --verify-only to run only the verification step without transferring.

Required arguments:
  --source EMAIL          Current owner (the user whose Drive is being transferred).
  --target EMAIL          New owner (the user receiving the Drive contents).

Options:
  --dest-folder VALUE     Folder ID, full Drive URL, or id:VALUE for an existing folder
                          in the target user's Drive. Transferred content lands here
                          instead of at the root of the target's My Drive.
  --dest-folder-name NAME Create a new folder with this name in the target user's My
                          Drive root, then transfer content into it. Cannot be combined
                          with --dest-folder.
  --scan-access           Before transferring, identify files the target user can
                          already access. Those files have ownership transferred in
                          place (not moved); the main transfer then processes only
                          the remaining files. In preview mode, reports counts only.
  --create-shortcuts      Before transferring, create Drive shortcuts in the source
                          user's My Drive for every file owned by an external account.
                          The shortcuts are owned by the source and are included in
                          the transfer. In preview mode, reports the count only.
  --gam PATH              GAM executable to use. Defaults to $GAM_CMD or `gam`.
  --execute               Apply the transfer. Without this flag, preview only.
  --retain-role ROLE      Role to assign to source after transfer:
                          reader, commenter, writer, editor, none.
  --exclude-trashed       Exclude trashed files from scans and verification.
                          By default, trashed files are included so that verification
                          produces a complete all-clear for offboarding.
  --verify-only           Verify source has no owned files without making changes.
  --no-verify             Skip post-execution verification.
  --report [FILE]         Write a Markdown report after the run. FILE is the output
                          path; if omitted, a name is generated automatically in the
                          current directory. Works in all modes including preview and
                          verify-only.
  --verbose               Print the resolved GAM command before running it.
  -h, --help              Show this help text.

Notes:
  - Only files and folders owned by the source user are transferred. Files in the
    source's My Drive that are owned by other users are never touched.
  - --scan-access uses the Drive query "'TARGET' in writers or 'TARGET' in readers",
    which matches files explicitly shared with the target. Access granted through a
    Google Group or a domain-wide "anyone with the link" permission is not detected.
  - --create-shortcuts places shortcuts at the root of the source's My Drive, which
    means they land directly inside --dest-folder (or TARGET's My Drive root if no
    dest folder is set). Shortcuts only preserve visibility; the target user may
    still need to request access to the underlying files from their external owners.
  - This operates on My Drive content only; Shared Drives are not affected.
  - --dest-folder must be a folder owned by the target user and already in their Drive.
  - Trashed files are included by default so that verification produces a complete
    all-clear. Use --exclude-trashed if you specifically do not want trash included
    in scans and verification.
  - --dest-folder-name creates the folder at execute time; it is not created during preview.
  - For single-folder transfers, use change_drive_folder_owner.sh instead.

Examples:
  Preview what would be transferred:
    ./transfer_user_drive.sh \
      --source departing.user@example.com \
      --target receiving.user@example.com

  Execute the transfer into an existing folder:
    ./transfer_user_drive.sh \
      --source departing.user@example.com \
      --target receiving.user@example.com \
      --dest-folder https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz \
      --execute

  Create a new folder and transfer into it:
    ./transfer_user_drive.sh \
      --source departing.user@example.com \
      --target receiving.user@example.com \
      --dest-folder-name "Departing User Files" \
      --execute

  Keep source as reader after transfer:
    ./transfer_user_drive.sh \
      --source departing.user@example.com \
      --target receiving.user@example.com \
      --retain-role reader \
      --execute

  Scan permissions and transfer (accessible files get ownership-only, rest get moved):
    ./transfer_user_drive.sh \
      --source departing.user@example.com \
      --target receiving.user@example.com \
      --dest-folder-name "Departing User Files" \
      --scan-access \
      --execute

  Create shortcuts for externally-owned files and transfer:
    ./transfer_user_drive.sh \
      --source departing.user@example.com \
      --target receiving.user@example.com \
      --dest-folder-name "Departing User Files" \
      --create-shortcuts \
      --execute

  Full transfer with report:
    ./transfer_user_drive.sh \
      --source departing.user@example.com \
      --target receiving.user@example.com \
      --dest-folder-name "Departing User Files" \
      --scan-access \
      --create-shortcuts \
      --report transfer_report.md \
      --execute

  Verify source has no remaining owned files:
    ./transfer_user_drive.sh \
      --source departing.user@example.com \
      --target receiving.user@example.com \
      --verify-only
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

  die "--dest-folder must be a Drive folder ID, full URL, or id:VALUE"
}

create_dest_folder() {
  local folder_id
  local -a create_cmd=(
    "$gam_bin"
    "user" "$target"
    "create" "drivefile"
    "drivefilename" "$dest_folder_name"
    "mimetype" "gfolder"
    "returnidonly"
  )

  if [[ "$verbose" == true ]]; then
    printf 'Create folder command: '
    print_command "${create_cmd[@]}"
  fi

  folder_id="$("${create_cmd[@]}")"
  folder_id="${folder_id//[$'\t\r\n ']}"

  [[ -n "$folder_id" ]] || die "Failed to create folder '${dest_folder_name}' or could not parse folder ID from GAM output"

  printf '%s\n' "$folder_id"
}

scan_and_transfer_accessible() {
  local accessible_csv
  local total_lines
  local accessible_count
  local -a scan_cmd=(
    "$gam_bin"
    "config" "csv_output_header_filter" "id,name"
    "redirect" "csv" ""
    "user" "$source"
    "print" "filelist"
    "showownedby" "me"
    "query" "'${target}' in writers or '${target}' in readers"
    "fields" "id,name"
  )

  accessible_csv="$(mktemp)"
  scan_cmd[6]="$accessible_csv"

  if [[ "$exclude_trashed" == true ]]; then
    scan_cmd+=("excludetrashed")
  fi

  printf 'Scanning for %s'\''s owned files already accessible to %s...\n' "$source" "$target"

  if [[ "$verbose" == true ]]; then
    printf 'Access scan command: '
    print_command "${scan_cmd[@]}"
  fi

  "${scan_cmd[@]}"

  total_lines="$(wc -l < "$accessible_csv")"

  if [[ "$total_lines" -le 1 ]]; then
    rm -f "$accessible_csv"
    printf 'None found; all owned files will be handled by the main transfer.\n'
    return 0
  fi

  accessible_count=$(( total_lines - 1 ))

  if [[ "$execute" == false ]]; then
    report_accessible_count="$accessible_count"
    if [[ "$emit_report" == true ]]; then
      report_accessible_csv="$accessible_csv"
    else
      rm -f "$accessible_csv"
    fi
    printf 'Found %s file(s) %s can already access.\n' "$accessible_count" "$target"
    printf 'In execute mode: ownership of these files would be transferred in place (not moved).\n'
    printf 'The main transfer would then process only the files %s cannot yet access.\n' "$target"
    return 0
  fi

  printf 'Found %s file(s) %s can already access — transferring ownership in place...\n' \
    "$accessible_count" "$target"

  local -a transfer_cmd=(
    "$gam_bin"
    "csv" "$accessible_csv"
    "gam" "user" "$source"
    "transfer" "ownership"
    "~id"
    "$target"
    "norecursion"
  )

  if [[ "$verbose" == true ]]; then
    printf 'In-place ownership transfer command: '
    print_command "${transfer_cmd[@]}"
  fi

  "${transfer_cmd[@]}"

  report_accessible_count="$accessible_count"
  if [[ "$emit_report" == true ]]; then
    report_accessible_csv="$accessible_csv"
  else
    rm -f "$accessible_csv"
  fi

  printf 'Ownership transferred for %s file(s). These files were not moved.\n' "$accessible_count"
  printf 'Proceeding with main transfer for remaining files...\n'
}

handle_external_files() {
  local filelist_csv
  local total_lines
  local external_count

  filelist_csv="$(mktemp)"

  printf 'Scanning %s'\''s Drive for externally-owned files...\n' "$source"

  local -a scan_cmd=(
    "$gam_bin"
    "config" "csv_output_header_filter" "id,name"
    "redirect" "csv" "$filelist_csv"
    "user" "$source"
    "print" "filelist"
    "showownedby" "others"
    "fields" "id,name"
    "excludetrashed"
  )

  if [[ "$verbose" == true ]]; then
    printf 'Scan command: '
    print_command "${scan_cmd[@]}"
  fi

  "${scan_cmd[@]}"

  total_lines="$(wc -l < "$filelist_csv")"
  if [[ "$total_lines" -le 1 ]]; then
    rm -f "$filelist_csv"
    printf 'No externally-owned files found.\n'
    return 0
  fi

  external_count=$(( total_lines - 1 ))

  if [[ "$execute" == false ]]; then
    report_shortcuts_count="$external_count"
    if [[ "$emit_report" == true ]]; then
      report_shortcuts_csv="$filelist_csv"
    else
      rm -f "$filelist_csv"
    fi
    printf 'Found %s externally-owned file(s). Re-run with --execute to create shortcuts.\n' \
      "$external_count"
    return 0
  fi

  printf 'Creating shortcuts for %s externally-owned file(s) in %s'\''s Drive...\n' \
    "$external_count" "$source"

  local -a shortcut_cmd=(
    "$gam_bin"
    "csv" "$filelist_csv"
    "gam" "user" "$source"
    "create" "drivefile"
    "shortcut" "~id"
  )

  if [[ "$verbose" == true ]]; then
    printf 'Shortcut command: '
    print_command "${shortcut_cmd[@]}"
  fi

  "${shortcut_cmd[@]}"

  report_shortcuts_count="$external_count"
  if [[ "$emit_report" == true ]]; then
    report_shortcuts_csv="$filelist_csv"
  else
    rm -f "$filelist_csv"
  fi

  printf '%s shortcut(s) created in %s'\''s My Drive root and will be included in the transfer.\n' \
    "$external_count" "$source"
  printf 'Note: %s may need to request access from external file owners to open them.\n' \
    "$target"
}

summarize_transfer_output() {
  local log_file="$1"
  local not_processed_count=0
  not_processed_count="$(grep -c -E 'Not Processed:|Drive Service/App not enabled' "$log_file" 2>/dev/null || true)"

  if [[ "$emit_report" == true && "$not_processed_count" -gt 0 ]]; then
    report_skipped_file="$(mktemp)"
    report_skipped_count="$not_processed_count"
    grep 'Not Processed:\|Drive Service/App not enabled' "$log_file" > "$report_skipped_file" || true
  fi

  if [[ "$not_processed_count" -eq 0 ]]; then
    return 0
  fi

  printf '\n%s file(s) were skipped. Explanations for the "Not Processed" messages above:\n' \
    "$not_processed_count"

  local count
  if grep -q 'Service not applicable for this address' "$log_file" 2>/dev/null; then
    count="$(grep -c 'Service not applicable for this address' "$log_file" 2>/dev/null || true)"
    printf '\n  [%s] "Not Processed: Service not applicable for this address: <email>"\n' "$count"
    printf '       The file is owned by an account outside your Google Workspace domain\n'
    printf '       (e.g. a personal Gmail or other external address). Google'\''s API does\n'
    printf '       not allow ownership of such files to be transferred via the Workspace\n'
    printf '       API. These files remain in the source user'\''s Drive unchanged.\n'
  fi

  if grep -q 'User not found' "$log_file" 2>/dev/null; then
    count="$(grep -c 'User not found' "$log_file" 2>/dev/null || true)"
    printf '\n  [%s] "Not Processed: User not found"\n' "$count"
    printf '       The file'\''s current owner account no longer exists in the domain.\n'
    printf '       Ownership cannot be transferred from a deleted account this way.\n'
  fi

  if grep -q 'Permission not found' "$log_file" 2>/dev/null; then
    count="$(grep -c 'Permission not found' "$log_file" 2>/dev/null || true)"
    printf '\n  [%s] "Not Processed: Permission not found"\n' "$count"
    printf '       The source user'\''s access to this file could not be verified.\n'
    printf '       The file may have had its sharing settings changed since it was indexed.\n'
  fi

  local disabled_count=0
  disabled_count="$(grep -c 'Drive Service/App not enabled' "$log_file" 2>/dev/null || true)"
  if [[ "$disabled_count" -gt 0 ]]; then
    printf '\n  [%s] "Drive Service/App not enabled"\n' "$disabled_count"
    printf '       A file owner'\''s account has Drive disabled — typically a suspended or\n'
    printf '       recently deleted domain account. These files are not owned by the source\n'
    printf '       user and cannot be transferred by this script. To recover them, use the\n'
    printf '       Google Workspace Admin Console to locate the disabled account'\''s Drive\n'
    printf '       and transfer it separately before the account is permanently deleted.\n'
  fi

  # Catch-all for any other Not Processed reasons not matched above
  local explained_count=0
  explained_count="$(grep -c -E \
    'Service not applicable for this address|User not found|Permission not found|Drive Service/App not enabled' \
    "$log_file" 2>/dev/null || true)"
  local other_count=$(( not_processed_count - explained_count ))
  if [[ "$other_count" -gt 0 ]]; then
    printf '\n  [%s] Other "Not Processed" reason(s) — see output above for details.\n' \
      "$other_count"
  fi

  printf '\n'
}

generate_report() {
  if [[ -z "$report_file" ]]; then
    local safe_source safe_target
    safe_source="${source//@/_}"
    safe_source="${safe_source//./_}"
    safe_target="${target//@/_}"
    safe_target="${safe_target//./_}"
    report_file="${safe_source}_to_${safe_target}_$(date +%Y%m%d_%H%M%S).md"
  fi

  local mode dest_label
  mode="$([[ "$execute" == true ]] && printf 'Execute' || printf 'Preview')"
  [[ "$verify_only" == true ]] && mode="Verify-only"

  if [[ -n "$dest_folder_id" && -n "$dest_folder_name" ]]; then
    dest_label="${dest_folder_name} (${dest_folder_id})"
  elif [[ -n "$dest_folder_id" ]]; then
    dest_label="$dest_folder_id"
  elif [[ -n "$dest_folder_name" ]]; then
    dest_label="${dest_folder_name} (not yet created)"
  else
    dest_label="Root of ${target}'s My Drive"
  fi

  {
    printf '# Drive Transfer Report\n\n'

    printf '| | |\n|---|---|\n'
    printf '| **Generated** | %s |\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '| **Mode** | %s |\n' "$mode"
    printf '| **Source** | %s |\n' "$source"
    printf '| **Target** | %s |\n' "$target"
    printf '| **Destination folder** | %s |\n' "$dest_label"
    printf '\n---\n\n'

    printf '## Summary\n\n'
    printf '| Category | Count |\n|---|---|\n'
    if [[ "$scan_access" == true ]]; then
      printf '| Files with ownership transferred in place | %s |\n' "$report_accessible_count"
    fi
    if [[ "$create_shortcuts" == true ]]; then
      printf '| Shortcuts created for externally-owned files | %s |\n' "$report_shortcuts_count"
    fi
    printf '| Files skipped (Not Processed) | %s |\n' "$report_skipped_count"
    printf '| Verification | %s |\n' "$report_verify_result"
    printf '\n'

    if [[ "$scan_access" == true ]]; then
      printf -- '---\n\n## Files with Ownership Transferred in Place\n\n'
      if [[ "$report_accessible_count" -gt 0 && -f "${report_accessible_csv:-/dev/null}" ]]; then
        printf '_These files were already accessible to %s. Ownership was transferred without moving them._\n\n' \
          "$target"
        printf '| File Name | File ID |\n|---|---|\n'
        python3 -c "
import csv, sys
with open(sys.argv[1]) as f:
    for row in csv.DictReader(f):
        name = row.get('name', '').replace('|', r'\|')
        print('| {} | {} |'.format(name, row.get('id', '')))
" "$report_accessible_csv"
        printf '\n'
      else
        printf '_No files found that %s already had access to._\n\n' "$target"
      fi
    fi

    if [[ "$create_shortcuts" == true ]]; then
      printf -- '---\n\n## Shortcuts Created for Externally-Owned Files\n\n'
      if [[ "$report_shortcuts_count" -gt 0 && -f "${report_shortcuts_csv:-/dev/null}" ]]; then
        printf '_These files are owned by accounts outside your domain. Shortcuts have been placed_\n'
        printf '_in the source user'\''s Drive and transferred to the destination folder._\n'
        printf '_The target user may need to request access from the external file owners._\n\n'
        printf '| File Name | File ID |\n|---|---|\n'
        python3 -c "
import csv, sys
with open(sys.argv[1]) as f:
    for row in csv.DictReader(f):
        name = row.get('name', '').replace('|', r'\|')
        print('| {} | {} |'.format(name, row.get('id', '')))
" "$report_shortcuts_csv"
        printf '\n'
      else
        printf '_No externally-owned files found._\n\n'
      fi
    fi

    if [[ "$report_skipped_count" -gt 0 && -f "${report_skipped_file:-/dev/null}" ]]; then
      printf -- '---\n\n## Skipped Files (Not Processed)\n\n'
      printf '_These files could not have ownership transferred._\n\n'
      printf '| User | File Name | Reason |\n|---|---|---|\n'
      # Format: "User: X, Drive File: NAME, Not Processed: REASON (N/TOTAL)"
      sed -n \
        's/User: \([^,]*\), Drive File: \(.*\), Not Processed: \(.*\) ([0-9][0-9]*\/[0-9][0-9]*)/| \1 | \2 | \3 |/p' \
        "$report_skipped_file"
      # Format: "User: X, Drive Service/App not enabled"
      sed -n \
        's/User: \([^,]*\), Drive Service\/App not enabled.*/| \1 | — | Drive Service\/App not enabled (account suspended or deleted) |/p' \
        "$report_skipped_file"
      printf '\n'
    fi

    printf -- '---\n\n## Verification\n\n%s\n' "$report_verify_result"

  } > "$report_file"

  [[ -n "${report_accessible_csv:-}" ]] && rm -f "$report_accessible_csv"
  [[ -n "${report_shortcuts_csv:-}" ]]  && rm -f "$report_shortcuts_csv"
  [[ -n "${report_skipped_file:-}" ]]   && rm -f "$report_skipped_file"

  printf 'Report written to: %s\n' "$report_file"
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
  local total_lines=0
  local remaining_count=0
  local -a verify_cmd=(
    "$gam_bin"
    "config" "csv_output_header_filter" "Owner,id,owners.0.emailAddress"
    "redirect" "csv" ""
    "user" "$source"
    "print" "filelist"
    "showownedby" "me"
    "fields" "id,owners.emailaddress"
  )

  verify_csv="$(mktemp)"
  verify_cmd[6]="$verify_csv"

  if [[ "$exclude_trashed" == true ]]; then
    verify_cmd+=("excludetrashed")
  fi

  if [[ "$verbose" == true ]]; then
    printf 'Verify command: '
    print_command "${verify_cmd[@]}"
  fi

  "${verify_cmd[@]}"

  total_lines="$(wc -l < "$verify_csv")"

  # A result with only a header line (or empty) means no owned files remain.
  if [[ "$total_lines" -le 1 ]]; then
    rm -f "$verify_csv"
    report_verify_result="Passed — ${source} has no remaining owned files in My Drive."
    printf 'Verification successful: %s has no remaining owned files in My Drive.\n' "$source"
    return 0
  fi

  remaining_count=$((total_lines - 1))
  report_verify_result="Failed — ${source} still owns ${remaining_count} file(s) in My Drive."
  printf 'Verification: %s still owns %s file(s) in My Drive.\n' "$source" "$remaining_count" >&2
  printf 'Remaining owned files (Owner,id,owners.0.emailAddress):\n' >&2
  sed -n '1,21p' "$verify_csv" >&2
  if [[ "$remaining_count" -gt 20 ]]; then
    printf 'Showing first 20 remaining files.\n' >&2
  fi
  rm -f "$verify_csv"
  exit 1
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

source=""
target=""
dest_folder_input=""
dest_folder_name=""
gam_bin="${GAM_CMD:-gam}"
execute=false
verify_only=false
verify=true
scan_access=false
create_shortcuts=false
exclude_trashed=false
retain_role=""
verbose=false
emit_report=false
report_file=""
report_accessible_csv=""
report_accessible_count=0
report_shortcuts_csv=""
report_shortcuts_count=0
report_skipped_file=""
report_skipped_count=0
report_verify_result="not run"

trap 'if [[ "$emit_report" == true ]]; then generate_report; fi' EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      require_value "$1" "${2-}"
      source="$2"
      shift 2
      ;;
    --target)
      require_value "$1" "${2-}"
      target="$2"
      shift 2
      ;;
    --dest-folder)
      require_value "$1" "${2-}"
      dest_folder_input="$2"
      shift 2
      ;;
    --dest-folder-name)
      require_value "$1" "${2-}"
      dest_folder_name="$2"
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
    --scan-access)
      scan_access=true
      shift
      ;;
    --create-shortcuts)
      create_shortcuts=true
      shift
      ;;
    --retain-role)
      require_value "$1" "${2-}"
      retain_role="$2"
      shift 2
      ;;
    --exclude-trashed)
      exclude_trashed=true
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
    --report)
      emit_report=true
      if [[ -n "${2-}" && "${2}" != -* ]]; then
        report_file="$2"
        shift 2
      else
        shift
      fi
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

[[ -n "$source" ]] || die "Missing required argument: --source"
[[ -n "$target" ]] || die "Missing required argument: --target"

is_valid_email "$source" || die "Invalid --source email address: $source"
is_valid_email "$target" || die "Invalid --target email address: $target"

[[ "$source" != "$target" ]] || die "--source and --target must be different users"

if [[ -n "$dest_folder_input" && -n "$dest_folder_name" ]]; then
  die "--dest-folder and --dest-folder-name cannot be used together"
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

if [[ "$execute" == true && "$verify_only" == true ]]; then
  die "--execute and --verify-only cannot be used together"
fi

gam_bin="$(resolve_gam_bin "$gam_bin")"

dest_folder_id=""
if [[ -n "$dest_folder_input" ]]; then
  dest_folder_id="$(extract_drive_id "$dest_folder_input")"
fi

if [[ -n "$dest_folder_name" && "$execute" == true ]]; then
  printf 'Creating destination folder "%s" in %s'\''s Drive...\n' "$dest_folder_name" "$target"
  dest_folder_id="$(create_dest_folder)"
  printf 'Destination folder created with ID: %s\n' "$dest_folder_id"
fi

if [[ "$verify_only" == true ]]; then
  printf 'Mode: verify-only\n'
  printf 'Source: %s\n' "$source"
  printf 'Target: %s\n' "$target"
  verify_ownership
  exit 0
fi

if [[ "$scan_access" == true ]]; then
  scan_and_transfer_accessible
fi

if [[ "$create_shortcuts" == true ]]; then
  handle_external_files
fi

declare -a cmd=("$gam_bin" "user" "$source" "transfer" "drive" "$target")

if [[ -n "$dest_folder_id" ]]; then
  cmd+=("targetfolderid" "$dest_folder_id")
fi

if [[ -n "$retain_role" ]]; then
  cmd+=("retainrole" "$retain_role")
fi

# transfer drive handles trashed files by default; includetrashed is not a valid flag for it.

if [[ "$execute" == false ]]; then
  cmd+=("preview")
fi

if [[ "$verbose" == true || "$execute" == false ]]; then
  printf 'Mode: transfer drive\n'
  printf 'Source: %s\n' "$source"
  printf 'Target: %s\n' "$target"
  if [[ -n "$dest_folder_id" ]]; then
    printf 'Destination folder: %s\n' "$dest_folder_id"
  elif [[ -n "$dest_folder_name" ]]; then
    printf 'Destination folder: (will create "%s" in %s'\''s Drive at execute time)\n' "$dest_folder_name" "$target"
  else
    printf 'Destination folder: (root of target My Drive)\n'
  fi
  printf 'Command: '
  print_command "${cmd[@]}"
fi

if [[ "$execute" == false ]]; then
  printf 'Preview only: no files will be transferred. Re-run with --execute to apply.\n'
  "${cmd[@]}"
  printf 'Preview complete. No files were transferred.\n'
  exit 0
fi

transfer_log="$(mktemp)"
"${cmd[@]}" 2>&1 | tee "$transfer_log" || true
transfer_exit="${PIPESTATUS[0]}"
summarize_transfer_output "$transfer_log"
rm -f "$transfer_log"

if [[ "$transfer_exit" -ne 0 ]]; then
  printf 'GAM exited with status %s. Review the output above.\n' "$transfer_exit" >&2
  exit "$transfer_exit"
fi

if [[ "$verify" == true ]]; then
  verify_ownership
else
  report_verify_result="Skipped (--no-verify)"
  printf 'Execution complete. Verification skipped.\n'
fi
