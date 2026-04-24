#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  manage_gmail_delegates.sh --mailbox EMAIL (--delegate EMAIL | --delegates LIST | --delegate-file FILE) [options]

Description:
  Add or remove Gmail delegates for a target mailbox with standard GAM.

  By default, the script runs in dry-run mode and prints the GAM command it would run.
  Add --execute to apply the change.

Required arguments:
  --mailbox EMAIL         Target mailbox that will grant or remove delegation.

Delegate input:
  --delegate EMAIL        Delegate email address. Repeat this flag for multiple delegates.
  --delegates LIST        Comma-separated delegate email list.
  --delegate-file FILE    File containing one delegate email per line.

Options:
  --remove                Remove delegation instead of adding it.
  --convert-alias         Pass GAM's convertalias option for delegate addresses.
  --gam PATH              GAM executable to use. Defaults to $GAM_CMD or `gam`.
  --execute               Apply the change. Without this flag, dry-run only.
  --verbose               Print the resolved GAM command before running it.
  -h, --help              Show this help text.

Notes:
  - Gmail delegation must be enabled for the mailbox and delegate org units.
  - Delegate aliases are not valid unless GAM converts them to primary addresses.
  - Dry-run mode only validates inputs and prints the final GAM command.

Examples:
  Preview adding two delegates:
    ./manage_gmail_delegates.sh \
      --mailbox shared.inbox@example.com \
      --delegate alice@example.com \
      --delegate bob@example.com

  Execute an add using a comma-separated list:
    ./manage_gmail_delegates.sh \
      --mailbox shared.inbox@example.com \
      --delegates alice@example.com,bob@example.com \
      --execute

  Execute a removal using a file:
    ./manage_gmail_delegates.sh \
      --mailbox shared.inbox@example.com \
      --delegate-file delegates.txt \
      --remove \
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

add_delegate_value() {
  local raw="$1"
  local part

  IFS=',' read -r -a split_parts <<< "$raw"
  for part in "${split_parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -n "$part" ]] || continue
    delegate_inputs+=("$part")
  done
}

load_delegate_file() {
  local file_path="$1"
  local line=""

  [[ -f "$file_path" ]] || die "Delegate file not found: $file_path"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    add_delegate_value "$line"
  done < "$file_path"
}

append_unique_delegate() {
  local candidate="$1"
  local existing

  if [[ "${#validated_delegates[@]}" -gt 0 ]]; then
    for existing in "${validated_delegates[@]}"; do
      if [[ "$existing" == "$candidate" ]]; then
        return 0
      fi
    done
  fi

  validated_delegates+=("$candidate")
}

mailbox=""
gam_bin="${GAM_CMD:-gam}"
execute=false
remove=false
convert_alias=false
verbose=false
delegate_file=""
declare -a delegate_inputs=()
declare -a validated_delegates=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mailbox)
      require_value "$1" "${2-}"
      mailbox="$2"
      shift 2
      ;;
    --delegate)
      require_value "$1" "${2-}"
      add_delegate_value "$2"
      shift 2
      ;;
    --delegates)
      require_value "$1" "${2-}"
      add_delegate_value "$2"
      shift 2
      ;;
    --delegate-file)
      require_value "$1" "${2-}"
      delegate_file="$2"
      shift 2
      ;;
    --remove)
      remove=true
      shift
      ;;
    --convert-alias)
      convert_alias=true
      shift
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

[[ -n "$mailbox" ]] || die "Missing required argument: --mailbox"
is_valid_email "$mailbox" || die "Invalid --mailbox email address: $mailbox"

if [[ -n "$delegate_file" ]]; then
  load_delegate_file "$delegate_file"
fi

[[ "${#delegate_inputs[@]}" -gt 0 ]] || die "Provide at least one delegate with --delegate, --delegates, or --delegate-file"

for delegate in "${delegate_inputs[@]}"; do
  is_valid_email "$delegate" || die "Invalid delegate email address: $delegate"
  append_unique_delegate "$delegate"
done

gam_bin="$(resolve_gam_bin "$gam_bin")"

delegate_csv=""
for delegate in "${validated_delegates[@]}"; do
  if [[ -n "$delegate_csv" ]]; then
    delegate_csv+=","
  fi
  delegate_csv+="$delegate"
done

declare -a cmd=("$gam_bin" "user" "$mailbox")

if [[ "$remove" == true ]]; then
  cmd+=("delete" "delegates")
else
  cmd+=("add" "delegates")
fi

if [[ "$convert_alias" == true ]]; then
  cmd+=("convertalias")
fi

cmd+=("$delegate_csv")

if [[ "$verbose" == true || "$execute" == false ]]; then
  if [[ "$remove" == true ]]; then
    printf 'Mode: remove\n'
  else
    printf 'Mode: add\n'
  fi
  printf 'Mailbox: %s\n' "$mailbox"
  printf 'Delegates: %s\n' "$delegate_csv"
  printf 'Command: '
  print_command "${cmd[@]}"
fi

if [[ "$execute" == false ]]; then
  exit 0
fi

exec "${cmd[@]}"
