#!/bin/bash
VERSION=v0.1.0

# Chrome History DB path (auto-detect by OS)
function _get_history_db {
  local os=$(uname)
  local chrome_dir
  if [ "$os" = "Darwin" ]; then
    chrome_dir="$HOME/Library/Application Support/Google/Chrome"
  elif [ "$os" = "Linux" ]; then
    chrome_dir="$HOME/.config/google-chrome"
  else
    # Windows (Git Bash / WSL)
    chrome_dir="${LOCALAPPDATA:-$USERPROFILE/AppData/Local}/Google/Chrome/User Data"
  fi

  # Try Default profile first, then Profile N
  if [ -f "$chrome_dir/Default/History" ]; then
    echo "$chrome_dir/Default/History"
  else
    local profile
    profile=$(find "$chrome_dir" -maxdepth 1 -name "Profile *" -type d 2>/dev/null | sort | head -1)
    if [ -n "$profile" ] && [ -f "$profile/History" ]; then
      echo "$profile/History"
    else
      echo "$chrome_dir/Default/History"
    fi
  fi
}

# Copy history DB to temp file to avoid lock issues
function _prepare_db {
  local db_path="${CHROME_HISTORY_DB:-$(_get_history_db)}"
  if [ ! -f "$db_path" ]; then
    echo "Error: Chrome history DB not found: $db_path" >&2
    echo "Set CHROME_HISTORY_DB env var to specify the path." >&2
    return 1
  fi
  local tmp=$(mktemp "${TMPDIR:-${TEMP:-/tmp}}/chrome_history_XXXXXX.db")
  cp "$db_path" "$tmp" 2>/dev/null
  echo "$tmp"
}

# Convert date string (YYYY-MM-DD) to Chrome timestamp (microseconds since 1601-01-01)
function _date_to_chrome_ts {
  local date_str="$1"
  local epoch_secs
  if date --version >/dev/null 2>&1; then
    # GNU date
    epoch_secs=$(date -d "$date_str" +%s 2>/dev/null)
  else
    # macOS date
    epoch_secs=$(date -j -f "%Y-%m-%d" "$date_str" +%s 2>/dev/null)
  fi
  if [ -z "$epoch_secs" ]; then
    echo "Error: Invalid date format: $date_str (use YYYY-MM-DD)" >&2
    return 1
  fi
  # Chrome epoch offset: seconds from 1601-01-01 to 1970-01-01
  local chrome_epoch_offset=11644473600
  echo $(( (epoch_secs + chrome_epoch_offset) * 1000000 ))
}

# Build WHERE clause for date range filtering
function _build_date_filter {
  local time_col="$1"
  local from="$2"
  local to="$3"
  local where=""

  if [ -n "$from" ]; then
    local from_ts=$(_date_to_chrome_ts "$from") || return 1
    where="${time_col} >= ${from_ts}"
  fi
  if [ -n "$to" ]; then
    local to_ts=$(_date_to_chrome_ts "$to") || return 1
    # to date is inclusive: add 1 day
    to_ts=$((to_ts + 86400000000))
    if [ -n "$where" ]; then
      where="${where} AND ${time_col} < ${to_ts}"
    else
      where="${time_col} < ${to_ts}"
    fi
  fi
  echo "$where"
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

# Run sqlite3 query with proper settings
function _query {
  local db="$1"
  local sql="$2"
  local sep="${3:-$'\t'}"
  sqlite3 -separator "$sep" "$db" "$sql"
}

# display help information for all available commands.
# use --brief to show only command descriptions without header.
function help {
  local brief=false
  if [ "$1" = "--brief" ]; then
    brief=true
  fi

  local funcNames=$(grep '^function' $0 | awk '{print $2}' | grep -v '^_')
  local cmd=$(cmd=$(basename $0); echo "${cmd%.*}")

  # ANSI color codes
  local PURPLE=$'\033[35m'
  local CYAN=$'\033[36m'
  local GREEN=$'\033[32m'
  local BRIGHT_GREEN=$'\033[92m'
  local RESET=$'\033[0m'

  # OS-specific reverse command
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
${PURPLE}${cmd}${RESET} (${CYAN}${VERSION}${RESET})

Usage: ${PURPLE}$0${RESET} <${BRIGHT_GREEN}command${RESET}> [options]

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
    local startLine=$(grep -n "^function ${funcName} " $0 | cut -d: -f1)
    if [ ! -z "$startLine" ]; then
      echo -e "\n${GREEN}${funcName}${RESET}:"
      awk "NR < $startLine" $0 | eval "$REVERSE_CMD" | awk '/^#/{flag=1; if(length($0)>1) print; else print ""} flag && /^$/{exit}' | eval "$REVERSE_CMD" | sed 's/^# //;s/^/  /'
    fi
  done

  if [ "$brief" = false ]; then
    echo ""
  fi
}

# display the current version of this command.
function version {
  echo ${VERSION}
}

# select and execute a subcommand interactively with fzf.
function fzf {
  local funcNames=$(grep '^function' $0 | awk '{print $2}' | grep -v '^_' | grep -v '^fzf$')
  local selected=$(echo "$funcNames" | command fzf --prompt="Select command: ")
  if [ -n "$selected" ]; then
    $0 "$selected" "$@"
  fi
}

# Extract visited URLs with title, visit count, and last visit time.
#
# Output columns: url | title | visit_count | typed_count | last_visit_time
#
# Options:
#   --from, -f <YYYY-MM-DD>  Start date
#   --to, -t <YYYY-MM-DD>    End date
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
function urls {
  local from="" to="" limit=100 format="tsv"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|-f) from="$2"; shift 2 ;;
      --to|-t) to="$2"; shift 2 ;;
      --limit|-n) limit="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _output_setup "$format"
  local db
  db=$(_prepare_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_date_filter "last_visit_time" "$from" "$to") || return 1

  local sql="SELECT url, title, visit_count, typed_count,
    datetime(last_visit_time/1000000 - 11644473600, 'unixepoch', 'localtime') as last_visit
    FROM urls"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY last_visit_time DESC LIMIT $limit;"

  echo "url${SEP}title${SEP}visit_count${SEP}typed_count${SEP}last_visit_time"
  _query "$db" "$sql" "$SEP"
}

# Extract individual visit records with transition info and duration.
#
# Output columns: url | title | visit_time | visit_duration_sec | transition | from_url
#
# Options:
#   --from, -f <YYYY-MM-DD>  Start date
#   --to, -t <YYYY-MM-DD>    End date
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
function visits {
  local from="" to="" limit=100 format="tsv"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|-f) from="$2"; shift 2 ;;
      --to|-t) to="$2"; shift 2 ;;
      --limit|-n) limit="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _output_setup "$format"
  local db
  db=$(_prepare_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_date_filter "v.visit_time" "$from" "$to") || return 1

  local sql="SELECT u.url, u.title,
    datetime(v.visit_time/1000000 - 11644473600, 'unixepoch', 'localtime') as visit_time,
    ROUND(v.visit_duration/1000000.0, 1) as duration_sec,
    CASE (v.transition & 0xFF)
      WHEN 0 THEN 'LINK'
      WHEN 1 THEN 'TYPED'
      WHEN 2 THEN 'BOOKMARK'
      WHEN 3 THEN 'AUTO_SUBFRAME'
      WHEN 4 THEN 'MANUAL_SUBFRAME'
      WHEN 5 THEN 'GENERATED'
      WHEN 6 THEN 'AUTO_TOPLEVEL'
      WHEN 7 THEN 'FORM_SUBMIT'
      WHEN 8 THEN 'RELOAD'
      WHEN 9 THEN 'KEYWORD'
      WHEN 10 THEN 'KEYWORD_GENERATED'
      ELSE 'OTHER(' || (v.transition & 0xFF) || ')'
    END as transition_type,
    COALESCE(fu.url, '') as from_url
    FROM visits v
    JOIN urls u ON v.url = u.id
    LEFT JOIN visits fv ON v.from_visit = fv.id
    LEFT JOIN urls fu ON fv.url = fu.id"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY v.visit_time DESC LIMIT $limit;"

  echo "url${SEP}title${SEP}visit_time${SEP}duration_sec${SEP}transition${SEP}from_url"
  _query "$db" "$sql" "$SEP"
}

# Extract search keywords from Chrome's keyword_search_terms table.
#
# Output columns: term | url | title | last_visit_time
#
# Options:
#   --from, -f <YYYY-MM-DD>  Start date
#   --to, -t <YYYY-MM-DD>    End date
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
function searches {
  local from="" to="" limit=100 format="tsv"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|-f) from="$2"; shift 2 ;;
      --to|-t) to="$2"; shift 2 ;;
      --limit|-n) limit="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _output_setup "$format"
  local db
  db=$(_prepare_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_date_filter "u.last_visit_time" "$from" "$to") || return 1

  local sql="SELECT k.term, u.url, u.title,
    datetime(u.last_visit_time/1000000 - 11644473600, 'unixepoch', 'localtime') as last_visit
    FROM keyword_search_terms k
    JOIN urls u ON k.url_id = u.id"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY u.last_visit_time DESC LIMIT $limit;"

  echo "term${SEP}url${SEP}title${SEP}last_visit_time"
  _query "$db" "$sql" "$SEP"
}

# Extract download history with file path, size, and status.
#
# Output columns: target_path | total_bytes | mime_type | state | start_time | tab_url | referrer
#
# Options:
#   --from, -f <YYYY-MM-DD>  Start date
#   --to, -t <YYYY-MM-DD>    End date
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
function downloads {
  local from="" to="" limit=100 format="tsv"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|-f) from="$2"; shift 2 ;;
      --to|-t) to="$2"; shift 2 ;;
      --limit|-n) limit="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _output_setup "$format"
  local db
  db=$(_prepare_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_date_filter "start_time" "$from" "$to") || return 1

  local sql="SELECT target_path, total_bytes, mime_type,
    CASE state
      WHEN 0 THEN 'IN_PROGRESS'
      WHEN 1 THEN 'COMPLETE'
      WHEN 2 THEN 'CANCELLED'
      WHEN 3 THEN 'INTERRUPTED'
      ELSE 'UNKNOWN(' || state || ')'
    END as state,
    datetime(start_time/1000000 - 11644473600, 'unixepoch', 'localtime') as start_time,
    COALESCE(tab_url, '') as tab_url,
    COALESCE(referrer, '') as referrer
    FROM downloads"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY start_time DESC LIMIT $limit;"

  echo "target_path${SEP}total_bytes${SEP}mime_type${SEP}state${SEP}start_time${SEP}tab_url${SEP}referrer"
  _query "$db" "$sql" "$SEP"
}

# Extract content annotations (page categories, language, search terms).
#
# Output columns: url | title | visit_time | categories | page_language | search_terms
#
# Options:
#   --from, -f <YYYY-MM-DD>  Start date
#   --to, -t <YYYY-MM-DD>    End date
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
function annotations {
  local from="" to="" limit=100 format="tsv"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|-f) from="$2"; shift 2 ;;
      --to|-t) to="$2"; shift 2 ;;
      --limit|-n) limit="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _output_setup "$format"
  local db
  db=$(_prepare_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_date_filter "v.visit_time" "$from" "$to") || return 1

  local sql="SELECT u.url, u.title,
    datetime(v.visit_time/1000000 - 11644473600, 'unixepoch', 'localtime') as visit_time,
    COALESCE(ca.categories, '') as categories,
    COALESCE(ca.page_language, '') as page_language,
    COALESCE(ca.search_terms, '') as search_terms
    FROM content_annotations ca
    JOIN visits v ON ca.visit_id = v.id
    JOIN urls u ON v.url = u.id"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY v.visit_time DESC LIMIT $limit;"

  echo "url${SEP}title${SEP}visit_time${SEP}categories${SEP}page_language${SEP}search_terms"
  _query "$db" "$sql" "$SEP"
}

# Extract context annotations (foreground duration, response code, tab/window info).
#
# Output columns: url | title | visit_time | foreground_duration_sec | response_code | tab_id | window_id
#
# Options:
#   --from, -f <YYYY-MM-DD>  Start date
#   --to, -t <YYYY-MM-DD>    End date
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
function contexts {
  local from="" to="" limit=100 format="tsv"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|-f) from="$2"; shift 2 ;;
      --to|-t) to="$2"; shift 2 ;;
      --limit|-n) limit="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _output_setup "$format"
  local db
  db=$(_prepare_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_date_filter "v.visit_time" "$from" "$to") || return 1

  local sql="SELECT u.url, u.title,
    datetime(v.visit_time/1000000 - 11644473600, 'unixepoch', 'localtime') as visit_time,
    ROUND(ctx.total_foreground_duration/1000000.0, 1) as foreground_sec,
    ctx.response_code,
    ctx.tab_id,
    ctx.window_id
    FROM context_annotations ctx
    JOIN visits v ON ctx.visit_id = v.id
    JOIN urls u ON v.url = u.id"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY v.visit_time DESC LIMIT $limit;"

  echo "url${SEP}title${SEP}visit_time${SEP}foreground_sec${SEP}response_code${SEP}tab_id${SEP}window_id"
  _query "$db" "$sql" "$SEP"
}

# Show summary statistics for a given date range.
#
# Displays: total visits, unique URLs, top domains, total browsing time.
#
# Options:
#   --from, -f <YYYY-MM-DD>  Start date
#   --to, -t <YYYY-MM-DD>    End date
function summary {
  local from="" to=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from|-f) from="$2"; shift 2 ;;
      --to|-t) to="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local db
  db=$(_prepare_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_date_filter "v.visit_time" "$from" "$to") || return 1
  local where_clause=""
  [ -n "$where" ] && where_clause="WHERE $where"

  echo "=== Chrome History Summary ==="
  [ -n "$from" ] && echo "From: $from"
  [ -n "$to" ] && echo "To: $to"
  echo ""

  echo "--- Basic Stats ---"
  _query "$db" "SELECT
    COUNT(*) as total_visits,
    COUNT(DISTINCT v.url) as unique_urls,
    ROUND(SUM(v.visit_duration)/1000000.0/3600, 2) as total_hours
    FROM visits v $where_clause;" $'\t' | awk -F'\t' '{
    printf "Total visits:    %s\n", $1
    printf "Unique URLs:     %s\n", $2
    printf "Total duration:  %s hours\n", $3
  }'

  echo ""
  echo "--- Top 10 Domains ---"
  _query "$db" "SELECT
    REPLACE(REPLACE(SUBSTR(u.url, INSTR(u.url, '://') + 3), 'www.', ''),
      SUBSTR(REPLACE(SUBSTR(u.url, INSTR(u.url, '://') + 3), 'www.', ''),
        INSTR(REPLACE(SUBSTR(u.url, INSTR(u.url, '://') + 3), 'www.', ''), '/')), '') as domain,
    COUNT(*) as cnt
    FROM visits v
    JOIN urls u ON v.url = u.id
    $where_clause
    GROUP BY domain
    ORDER BY cnt DESC
    LIMIT 10;" $'\t' | awk -F'\t' '{printf "  %-40s %s visits\n", $1, $2}'

  echo ""
  echo "--- Transition Types ---"
  _query "$db" "SELECT
    CASE (v.transition & 0xFF)
      WHEN 0 THEN 'LINK'
      WHEN 1 THEN 'TYPED'
      WHEN 2 THEN 'BOOKMARK'
      WHEN 7 THEN 'FORM_SUBMIT'
      WHEN 8 THEN 'RELOAD'
      WHEN 9 THEN 'KEYWORD'
      ELSE 'OTHER'
    END as type,
    COUNT(*) as cnt
    FROM visits v
    $where_clause
    GROUP BY type
    ORDER BY cnt DESC;" $'\t' | awk -F'\t' '{printf "  %-20s %s\n", $1, $2}'
}

# Get Chrome profile directory
function _get_chrome_profile_dir {
  local os=$(uname)
  local chrome_dir
  if [ "$os" = "Darwin" ]; then
    chrome_dir="$HOME/Library/Application Support/Google/Chrome"
  elif [ "$os" = "Linux" ]; then
    chrome_dir="$HOME/.config/google-chrome"
  else
    chrome_dir="${LOCALAPPDATA:-$USERPROFILE/AppData/Local}/Google/Chrome/User Data"
  fi

  if [ -d "$chrome_dir/Default" ]; then
    echo "$chrome_dir/Default"
  else
    local profile
    profile=$(find "$chrome_dir" -maxdepth 1 -name "Profile *" -type d 2>/dev/null | sort | head -1)
    if [ -n "$profile" ]; then
      echo "$profile"
    else
      echo "$chrome_dir/Default"
    fi
  fi
}

# Extract saved tabs from OneTab extension (LevelDB).
#
# Output columns: url | title | group_date
#
# Options:
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
#   --profile-dir <path>     Chrome profile directory (auto-detected)
function onetab {
  local limit=100 format="tsv" profile_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit|-n) limit="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      --profile-dir) profile_dir="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _output_setup "$format"

  if [ -z "$profile_dir" ]; then
    profile_dir=$(_get_chrome_profile_dir)
  fi

  local onetab_dir="$profile_dir/Local Extension Settings/chphlpgkkbolifaimnlloiipkdnihall"
  if [ ! -d "$onetab_dir" ]; then
    echo "Error: OneTab data not found: $onetab_dir" >&2
    echo "Is OneTab installed in this Chrome profile?" >&2
    return 1
  fi

  echo "url${SEP}title${SEP}group_date"

  local python_cmd="python3"
  if ! command -v python3 >/dev/null 2>&1; then
    python_cmd="python"
  fi

  "$python_cmd" -c "
import os, re, json, sys
from datetime import datetime, timezone

onetab_dir = sys.argv[1]
sep = sys.argv[2]
limit = int(sys.argv[3])

entries = []
for fname in sorted(os.listdir(onetab_dir)):
    if not (fname.endswith('.ldb') or fname.endswith('.log')):
        continue
    fpath = os.path.join(onetab_dir, fname)
    try:
        with open(fpath, 'rb') as f:
            raw = f.read()
    except:
        continue
    text = raw.decode('utf-8', errors='replace')
    clean = text.replace('\\\\\"', '\"')

    # Find tab groups with createDate
    for gm in re.finditer(r'(\[(?:\{[^]]*\}[,\s]*)+\]),?\"createDate\":(\d+)', clean):
        try:
            group_json = gm.group(1)
            create_ts = int(gm.group(2))
            group_date = datetime.fromtimestamp(create_ts / 1000, tz=timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
            tabs = json.loads(group_json)
            for tab in tabs:
                url = tab.get('url', '')
                title = tab.get('title', '')
                if url:
                    entries.append((url, title, group_date))
        except:
            pass

    # Fallback: find individual url/title pairs without group context (per-file)
    if not any(e for e in entries if e[2]):
        for m in re.finditer(r'\"url\":\"(https?://[^\"]+)\",\"title\":\"([^\"]*)\"', clean):
            title = m.group(2)
            # Skip entries with binary garbage in title
            if any(ord(c) < 32 and c not in '\t\n\r' for c in title):
                title = re.sub(r'[^\x20-\x7E\u0080-\uffff]', '', title)
            entries.append((m.group(1), title, ''))

# Deduplicate by url, keeping first occurrence
seen = set()
unique = []
for url, title, gdate in entries:
    if url not in seen:
        seen.add(url)
        unique.append((url, title, gdate))

# Filter out entries with binary garbage in title or url
clean = []
for url, title, gdate in unique:
    if any(ord(c) < 32 and c not in '\t\n\r' for c in title):
        continue
    if any(ord(c) < 32 for c in url):
        continue
    # Skip titles with replacement characters (LevelDB corruption)
    if '\ufffd' in title or len(title) > 500:
        continue
    clean.append((url, title, gdate))

output = clean if limit <= 0 else clean[:limit]
for url, title, gdate in output:
    title = title.replace(sep, ' ')
    print(f'{url}{sep}{title}{sep}{gdate}')
" "$onetab_dir" "$SEP" "$limit"
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

cmd=$1
shift
case "$cmd" in
  help|-h|--help)
    help "$@"
    ;;

  version|-v|--version)
    version
    ;;

  fzf)
    fzf "$@"
    ;;

  urls)
    urls "$@"
    exit $?
    ;;

  visits)
    visits "$@"
    exit $?
    ;;

  searches)
    searches "$@"
    exit $?
    ;;

  downloads)
    downloads "$@"
    exit $?
    ;;

  annotations)
    annotations "$@"
    exit $?
    ;;

  contexts)
    contexts "$@"
    exit $?
    ;;

  summary)
    summary "$@"
    exit $?
    ;;

  onetab)
    onetab "$@"
    exit $?
    ;;

  *)
    help
    ;;
esac
