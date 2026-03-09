#!/bin/bash
# Microsoft Edge history subcommand (Chromium-based, same schema as Chrome)
VERSION=v0.2.0
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/../lib/common.sh"

BROWSER_NAME="Edge"
ENV_VAR="EDGE_HISTORY_DB"

function _get_db_path {
  if [ -n "${EDGE_HISTORY_DB}" ]; then
    echo "${EDGE_HISTORY_DB}"
    return
  fi
  local os=$(uname)
  local base_dir
  if [ "$os" = "Darwin" ]; then
    base_dir="$HOME/Library/Application Support/Microsoft Edge"
  elif [ "$os" = "Linux" ]; then
    base_dir="$HOME/.config/microsoft-edge"
  else
    base_dir="${LOCALAPPDATA:-$USERPROFILE/AppData/Local}/Microsoft/Edge/User Data"
  fi
  if [ -f "$base_dir/Default/History" ]; then
    echo "$base_dir/Default/History"
  else
    local profile
    profile=$(find "$base_dir" -maxdepth 1 -name "Profile *" -type d 2>/dev/null | sort | head -1)
    if [ -n "$profile" ] && [ -f "$profile/History" ]; then
      echo "$profile/History"
    else
      echo "$base_dir/Default/History"
    fi
  fi
}

function _get_prepared_db {
  local db_path=$(_get_db_path)
  local db
  db=$(_prepare_db "$db_path") || { echo "Set ${ENV_VAR} env var to specify the path." >&2; return 1; }
  echo "$db"
}

# display help for edge subcommands.
function help {
  _subcmd_help "$0" "$VERSION" "$@"
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
  _parse_opts "$@"
  _output_setup "$OPT_FORMAT"
  local db
  db=$(_get_prepared_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_chromium_date_filter "last_visit_time" "$OPT_FROM" "$OPT_TO") || return 1

  local sql="SELECT url, title, visit_count, typed_count,
    datetime(last_visit_time/1000000 - 11644473600, 'unixepoch', 'localtime') as last_visit
    FROM urls"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY last_visit_time DESC LIMIT $OPT_LIMIT;"

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
  _parse_opts "$@"
  _output_setup "$OPT_FORMAT"
  local db
  db=$(_get_prepared_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_chromium_date_filter "v.visit_time" "$OPT_FROM" "$OPT_TO") || return 1

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
  sql="$sql ORDER BY v.visit_time DESC LIMIT $OPT_LIMIT;"

  echo "url${SEP}title${SEP}visit_time${SEP}duration_sec${SEP}transition${SEP}from_url"
  _query "$db" "$sql" "$SEP"
}

# Extract search keywords from keyword_search_terms table.
#
# Output columns: term | url | title | last_visit_time
#
# Options:
#   --from, -f <YYYY-MM-DD>  Start date
#   --to, -t <YYYY-MM-DD>    End date
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
function searches {
  _parse_opts "$@"
  _output_setup "$OPT_FORMAT"
  local db
  db=$(_get_prepared_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_chromium_date_filter "u.last_visit_time" "$OPT_FROM" "$OPT_TO") || return 1

  local sql="SELECT k.term, u.url, u.title,
    datetime(u.last_visit_time/1000000 - 11644473600, 'unixepoch', 'localtime') as last_visit
    FROM keyword_search_terms k
    JOIN urls u ON k.url_id = u.id"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY u.last_visit_time DESC LIMIT $OPT_LIMIT;"

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
  _parse_opts "$@"
  _output_setup "$OPT_FORMAT"
  local db
  db=$(_get_prepared_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_chromium_date_filter "start_time" "$OPT_FROM" "$OPT_TO") || return 1

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
  sql="$sql ORDER BY start_time DESC LIMIT $OPT_LIMIT;"

  echo "target_path${SEP}total_bytes${SEP}mime_type${SEP}state${SEP}start_time${SEP}tab_url${SEP}referrer"
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
  _parse_opts "$@"
  local db
  db=$(_get_prepared_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_chromium_date_filter "v.visit_time" "$OPT_FROM" "$OPT_TO") || return 1
  local where_clause=""
  [ -n "$where" ] && where_clause="WHERE $where"

  echo "=== ${BROWSER_NAME} History Summary ==="
  [ -n "$OPT_FROM" ] && echo "From: $OPT_FROM"
  [ -n "$OPT_TO" ] && echo "To: $OPT_TO"
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
}

cmd=$1
shift
case "$cmd" in
  help|-h|--help) help "$@" ;;
  urls) urls "$@"; exit $? ;;
  visits) visits "$@"; exit $? ;;
  searches) searches "$@"; exit $? ;;
  downloads) downloads "$@"; exit $? ;;
  summary) summary "$@"; exit $? ;;
  *) help ;;
esac
