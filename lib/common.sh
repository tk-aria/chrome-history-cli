#!/bin/bash
# Common helper functions for all browser history extraction

# Copy history DB to temp file to avoid lock issues
function _prepare_db {
  local db_path="$1"
  if [ ! -f "$db_path" ]; then
    echo "Error: History DB not found: $db_path" >&2
    return 1
  fi
  local tmp=$(mktemp "${TMPDIR:-${TEMP:-/tmp}}/browser_history_XXXXXX.db")
  cp "$db_path" "$tmp" 2>/dev/null
  echo "$tmp"
}

# Output header and set separator based on format
function _output_setup {
  local format="$1"
  if [ "$format" = "csv" ]; then
    SEP=","
  else
    SEP=$'\t'
  fi
}

# Run sqlite3 query
function _query {
  local db="$1"
  local sql="$2"
  local sep="${3:-$'\t'}"
  sqlite3 -separator "$sep" "$db" "$sql"
}

# Convert date string (YYYY-MM-DD) to unix epoch seconds
function _date_to_epoch {
  local date_str="$1"
  local epoch_secs
  if date --version >/dev/null 2>&1; then
    epoch_secs=$(date -d "$date_str" +%s 2>/dev/null)
  else
    epoch_secs=$(date -j -f "%Y-%m-%d" "$date_str" +%s 2>/dev/null)
  fi
  if [ -z "$epoch_secs" ]; then
    echo "Error: Invalid date format: $date_str (use YYYY-MM-DD)" >&2
    return 1
  fi
  echo "$epoch_secs"
}

# Parse common options: --from, --to, --limit, --format
# Sets variables: OPT_FROM, OPT_TO, OPT_LIMIT, OPT_FORMAT
function _parse_opts {
  OPT_FROM=""
  OPT_TO=""
  OPT_LIMIT=100
  OPT_FORMAT="tsv"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|-f) OPT_FROM="$2"; shift 2 ;;
      --to|-t) OPT_TO="$2"; shift 2 ;;
      --limit|-n) OPT_LIMIT="$2"; shift 2 ;;
      --format) OPT_FORMAT="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

# Build WHERE clause for Chromium timestamps (microseconds since 1601-01-01)
function _build_chromium_date_filter {
  local time_col="$1"
  local from="$2"
  local to="$3"
  local chrome_epoch_offset=11644473600
  local where=""

  if [ -n "$from" ]; then
    local from_epoch=$(_date_to_epoch "$from") || return 1
    local from_ts=$(( (from_epoch + chrome_epoch_offset) * 1000000 ))
    where="${time_col} >= ${from_ts}"
  fi
  if [ -n "$to" ]; then
    local to_epoch=$(_date_to_epoch "$to") || return 1
    local to_ts=$(( (to_epoch + chrome_epoch_offset + 86400) * 1000000 ))
    if [ -n "$where" ]; then
      where="${where} AND ${time_col} < ${to_ts}"
    else
      where="${time_col} < ${to_ts}"
    fi
  fi
  echo "$where"
}

# Build WHERE clause for Firefox timestamps (microseconds since 1970-01-01)
function _build_firefox_date_filter {
  local time_col="$1"
  local from="$2"
  local to="$3"
  local where=""

  if [ -n "$from" ]; then
    local from_epoch=$(_date_to_epoch "$from") || return 1
    local from_ts=$(( from_epoch * 1000000 ))
    where="${time_col} >= ${from_ts}"
  fi
  if [ -n "$to" ]; then
    local to_epoch=$(_date_to_epoch "$to") || return 1
    local to_ts=$(( (to_epoch + 86400) * 1000000 ))
    if [ -n "$where" ]; then
      where="${where} AND ${time_col} < ${to_ts}"
    else
      where="${time_col} < ${to_ts}"
    fi
  fi
  echo "$where"
}

# Build WHERE clause for Safari timestamps (seconds since 2001-01-01)
function _build_safari_date_filter {
  local time_col="$1"
  local from="$2"
  local to="$3"
  local coredata_epoch_offset=978307200
  local where=""

  if [ -n "$from" ]; then
    local from_epoch=$(_date_to_epoch "$from") || return 1
    local from_ts=$(( from_epoch - coredata_epoch_offset ))
    where="${time_col} >= ${from_ts}"
  fi
  if [ -n "$to" ]; then
    local to_epoch=$(_date_to_epoch "$to") || return 1
    local to_ts=$(( to_epoch + 86400 - coredata_epoch_offset ))
    if [ -n "$where" ]; then
      where="${where} AND ${time_col} < ${to_ts}"
    else
      where="${time_col} < ${to_ts}"
    fi
  fi
  echo "$where"
}

# Subcommand help generator (cli.sh pattern)
function _subcmd_help {
  local script="$1"
  local version="$2"
  local brief=false
  if [ "$3" = "--brief" ]; then
    brief=true
  fi

  local funcNames=$(grep '^function' "$script" | awk '{print $2}' | grep -v '^_')
  local cmd=$(cmd=$(basename "$script"); echo "${cmd%.*}")

  local PURPLE=$'\033[35m'
  local CYAN=$'\033[36m'
  local GREEN=$'\033[32m'
  local BRIGHT_GREEN=$'\033[92m'
  local RESET=$'\033[0m'

  if [[ "$(uname)" == "Darwin" ]]; then
    REVERSE_CMD="tail -r"
  elif command -v tac >/dev/null 2>&1; then
    REVERSE_CMD="tac"
  else
    # Portable reverse for Git Bash / MSYS2 (no tac available)
    REVERSE_CMD="awk '{lines[NR]=\$0} END{for(i=NR;i>0;i--)print lines[i]}'"
  fi

  if [ "$brief" = false ]; then
    read -d '' header <<-EOF
${PURPLE}${cmd}${RESET} (${CYAN}${version}${RESET})

Usage: ${PURPLE}${script}${RESET} <${BRIGHT_GREEN}command${RESET}> [options]

Common Options:
  --from, -f <YYYY-MM-DD>    Start date (inclusive)
  --to, -t <YYYY-MM-DD>      End date (inclusive)
  --limit, -n <number>       Max rows (default: 100)
  --format <tsv|csv>         Output format (default: tsv)
EOF
    echo -e "$header"
  fi

  for funcName in $funcNames; do
    if [ "$brief" = true ] && { [ "$funcName" = "help" ] || [ "$funcName" = "version" ] || [ "$funcName" = "fzf" ]; }; then
      continue
    fi
    local startLine=$(grep -n "^function ${funcName} " "$script" | cut -d: -f1)
    if [ ! -z "$startLine" ]; then
      echo -e "\n${GREEN}${funcName}${RESET}:"
      awk "NR < $startLine" "$script" | eval "$REVERSE_CMD" | awk '/^#/{flag=1; if(length($0)>1) print; else print ""} flag && /^$/{exit}' | eval "$REVERSE_CMD" | sed 's/^# //;s/^/  /'
    fi
  done

  if [ "$brief" = false ]; then
    echo ""
  fi
}
