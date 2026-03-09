#!/bin/bash
# Shared functions for Chromium-based browsers (Chrome, Edge, Brave, Vivaldi, Opera)
# Each cmd/{chrome,edge}.sh sources this file and sets DB_PATH / BROWSER_NAME.

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$LIB_DIR/common.sh"

# Chromium datetime SQL expression
# Usage: printf -v var "$CHROMIUM_DT_EXPR" "column_name"
CHROMIUM_DT_EXPR="datetime(%s/1000000 - 11644473600, 'unixepoch', 'localtime')"

# Detect Chromium profile History DB path
function _detect_chromium_db {
  local base_dir="$1"
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

# --- Chromium subcommand implementations ---
# DB_PATH must be set before calling these functions.

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
  _parse_opts "$@"; _output_setup "$OPT_FORMAT"
  local db; db=$(_prepare_db "$DB_PATH") || return 1
  trap "rm -f '$db'" RETURN

  local where; where=$(_build_chromium_date_filter "last_visit_time" "$OPT_FROM" "$OPT_TO") || return 1
  local dt; printf -v dt "$CHROMIUM_DT_EXPR" "last_visit_time"

  local sql="SELECT url, title, visit_count, typed_count, $dt as last_visit FROM urls"
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
  _parse_opts "$@"; _output_setup "$OPT_FORMAT"
  local db; db=$(_prepare_db "$DB_PATH") || return 1
  trap "rm -f '$db'" RETURN

  local where; where=$(_build_chromium_date_filter "v.visit_time" "$OPT_FROM" "$OPT_TO") || return 1
  local dt; printf -v dt "$CHROMIUM_DT_EXPR" "v.visit_time"

  local sql="SELECT u.url, u.title, $dt as visit_time,
    ROUND(v.visit_duration/1000000.0, 1) as duration_sec,
    CASE (v.transition & 0xFF)
      WHEN 0 THEN 'LINK' WHEN 1 THEN 'TYPED' WHEN 2 THEN 'BOOKMARK'
      WHEN 3 THEN 'AUTO_SUBFRAME' WHEN 4 THEN 'MANUAL_SUBFRAME'
      WHEN 5 THEN 'GENERATED' WHEN 6 THEN 'AUTO_TOPLEVEL'
      WHEN 7 THEN 'FORM_SUBMIT' WHEN 8 THEN 'RELOAD'
      WHEN 9 THEN 'KEYWORD' WHEN 10 THEN 'KEYWORD_GENERATED'
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
  _parse_opts "$@"; _output_setup "$OPT_FORMAT"
  local db; db=$(_prepare_db "$DB_PATH") || return 1
  trap "rm -f '$db'" RETURN

  local where; where=$(_build_chromium_date_filter "u.last_visit_time" "$OPT_FROM" "$OPT_TO") || return 1
  local dt; printf -v dt "$CHROMIUM_DT_EXPR" "u.last_visit_time"

  local sql="SELECT k.term, u.url, u.title, $dt as last_visit
    FROM keyword_search_terms k JOIN urls u ON k.url_id = u.id"
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
  _parse_opts "$@"; _output_setup "$OPT_FORMAT"
  local db; db=$(_prepare_db "$DB_PATH") || return 1
  trap "rm -f '$db'" RETURN

  local where; where=$(_build_chromium_date_filter "start_time" "$OPT_FROM" "$OPT_TO") || return 1
  local dt; printf -v dt "$CHROMIUM_DT_EXPR" "start_time"

  local sql="SELECT target_path, total_bytes, mime_type,
    CASE state WHEN 0 THEN 'IN_PROGRESS' WHEN 1 THEN 'COMPLETE'
      WHEN 2 THEN 'CANCELLED' WHEN 3 THEN 'INTERRUPTED'
      ELSE 'UNKNOWN(' || state || ')' END as state,
    $dt as start_time, COALESCE(tab_url, '') as tab_url, COALESCE(referrer, '') as referrer
    FROM downloads"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY start_time DESC LIMIT $OPT_LIMIT;"

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
  _parse_opts "$@"; _output_setup "$OPT_FORMAT"
  local db; db=$(_prepare_db "$DB_PATH") || return 1
  trap "rm -f '$db'" RETURN

  local where; where=$(_build_chromium_date_filter "v.visit_time" "$OPT_FROM" "$OPT_TO") || return 1
  local dt; printf -v dt "$CHROMIUM_DT_EXPR" "v.visit_time"

  local sql="SELECT u.url, u.title, $dt as visit_time,
    COALESCE(ca.categories, '') as categories,
    COALESCE(ca.page_language, '') as page_language,
    COALESCE(ca.search_terms, '') as search_terms
    FROM content_annotations ca
    JOIN visits v ON ca.visit_id = v.id JOIN urls u ON v.url = u.id"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY v.visit_time DESC LIMIT $OPT_LIMIT;"

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
  _parse_opts "$@"; _output_setup "$OPT_FORMAT"
  local db; db=$(_prepare_db "$DB_PATH") || return 1
  trap "rm -f '$db'" RETURN

  local where; where=$(_build_chromium_date_filter "v.visit_time" "$OPT_FROM" "$OPT_TO") || return 1
  local dt; printf -v dt "$CHROMIUM_DT_EXPR" "v.visit_time"

  local sql="SELECT u.url, u.title, $dt as visit_time,
    ROUND(ctx.total_foreground_duration/1000000.0, 1) as foreground_sec,
    ctx.response_code, ctx.tab_id, ctx.window_id
    FROM context_annotations ctx
    JOIN visits v ON ctx.visit_id = v.id JOIN urls u ON v.url = u.id"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY v.visit_time DESC LIMIT $OPT_LIMIT;"

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

  local db; db=$(_prepare_db "$DB_PATH") || return 1
  trap "rm -f '$db'" RETURN

  local where; where=$(_build_chromium_date_filter "v.visit_time" "$from" "$to") || return 1
  local wc=""; [ -n "$where" ] && wc="WHERE $where"

  echo "=== ${BROWSER_NAME} History Summary ==="
  [ -n "$from" ] && echo "From: $from"
  [ -n "$to" ] && echo "To: $to"
  echo ""

  echo "--- Basic Stats ---"
  _query "$db" "SELECT COUNT(*), COUNT(DISTINCT v.url),
    ROUND(SUM(v.visit_duration)/1000000.0/3600, 2) FROM visits v $wc;" $'\t' |
    awk -F'\t' '{printf "Total visits:    %s\nUnique URLs:     %s\nTotal duration:  %s hours\n", $1, $2, $3}'

  echo ""
  echo "--- Top 10 Domains ---"
  _query "$db" "SELECT
    REPLACE(REPLACE(SUBSTR(u.url, INSTR(u.url,'://')+3),'www.',''),
      SUBSTR(REPLACE(SUBSTR(u.url, INSTR(u.url,'://')+3),'www.',''),
        INSTR(REPLACE(SUBSTR(u.url, INSTR(u.url,'://')+3),'www.',''),'/')), '') as domain,
    COUNT(*) as cnt FROM visits v JOIN urls u ON v.url=u.id $wc
    GROUP BY domain ORDER BY cnt DESC LIMIT 10;" $'\t' |
    awk -F'\t' '{printf "  %-40s %s visits\n", $1, $2}'

  echo ""
  echo "--- Transition Types ---"
  _query "$db" "SELECT
    CASE (v.transition & 0xFF) WHEN 0 THEN 'LINK' WHEN 1 THEN 'TYPED'
      WHEN 2 THEN 'BOOKMARK' WHEN 7 THEN 'FORM_SUBMIT'
      WHEN 8 THEN 'RELOAD' WHEN 9 THEN 'KEYWORD' ELSE 'OTHER'
    END as type, COUNT(*) as cnt FROM visits v $wc
    GROUP BY type ORDER BY cnt DESC;" $'\t' |
    awk -F'\t' '{printf "  %-20s %s\n", $1, $2}'
}
