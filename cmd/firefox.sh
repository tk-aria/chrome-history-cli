#!/bin/bash
# Firefox history subcommand (Mozilla places.sqlite)
VERSION=v0.2.0
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/../lib/common.sh"

BROWSER_NAME="Firefox"
ENV_VAR="FIREFOX_HISTORY_DB"

function _get_db_path {
  if [ -n "${FIREFOX_HISTORY_DB}" ]; then
    echo "${FIREFOX_HISTORY_DB}"
    return
  fi
  local os=$(uname)
  local base_dir
  if [ "$os" = "Darwin" ]; then
    base_dir="$HOME/Library/Application Support/Firefox/Profiles"
  elif [ "$os" = "Linux" ]; then
    base_dir="$HOME/.mozilla/firefox"
  else
    base_dir="$APPDATA/Mozilla/Firefox/Profiles"
  fi
  # Find the default-release profile, fallback to first .default profile
  local profile_dir
  profile_dir=$(find "$base_dir" -maxdepth 1 -name "*.default-release" -type d 2>/dev/null | head -1)
  if [ -z "$profile_dir" ]; then
    profile_dir=$(find "$base_dir" -maxdepth 1 -name "*.default*" -type d 2>/dev/null | head -1)
  fi
  if [ -n "$profile_dir" ] && [ -f "$profile_dir/places.sqlite" ]; then
    echo "$profile_dir/places.sqlite"
  else
    echo "$base_dir/places.sqlite"
  fi
}

function _get_prepared_db {
  local db_path=$(_get_db_path)
  local db
  db=$(_prepare_db "$db_path") || { echo "Set ${ENV_VAR} env var to specify the path." >&2; return 1; }
  echo "$db"
}

# display help for firefox subcommands.
function help {
  _subcmd_help "$0" "$VERSION" "$@"
}

# Extract visited URLs with title, visit count, and last visit time.
#
# Output columns: url | title | visit_count | last_visit_time
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

  local where=$(_build_firefox_date_filter "last_visit_date" "$OPT_FROM" "$OPT_TO") || return 1

  local sql="SELECT url, COALESCE(title, '') as title, visit_count,
    datetime(last_visit_date/1000000, 'unixepoch', 'localtime') as last_visit
    FROM moz_places
    WHERE visit_count > 0"
  if [ -n "$where" ]; then
    sql="$sql AND $where"
  fi
  sql="$sql ORDER BY last_visit_date DESC LIMIT $OPT_LIMIT;"

  echo "url${SEP}title${SEP}visit_count${SEP}last_visit_time"
  _query "$db" "$sql" "$SEP"
}

# Extract individual visit records with transition info.
#
# Output columns: url | title | visit_time | transition | from_url
#
# Firefox transition types:
#   1=LINK, 2=TYPED, 3=BOOKMARK, 4=EMBED, 5=REDIRECT_PERMANENT,
#   6=REDIRECT_TEMPORARY, 7=DOWNLOAD, 8=FRAMED_LINK, 9=RELOAD
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

  local where=$(_build_firefox_date_filter "v.visit_date" "$OPT_FROM" "$OPT_TO") || return 1

  local sql="SELECT p.url, COALESCE(p.title, '') as title,
    datetime(v.visit_date/1000000, 'unixepoch', 'localtime') as visit_time,
    CASE v.visit_type
      WHEN 1 THEN 'LINK'
      WHEN 2 THEN 'TYPED'
      WHEN 3 THEN 'BOOKMARK'
      WHEN 4 THEN 'EMBED'
      WHEN 5 THEN 'REDIRECT_PERM'
      WHEN 6 THEN 'REDIRECT_TEMP'
      WHEN 7 THEN 'DOWNLOAD'
      WHEN 8 THEN 'FRAMED_LINK'
      WHEN 9 THEN 'RELOAD'
      ELSE 'OTHER(' || v.visit_type || ')'
    END as transition_type,
    COALESCE(fp.url, '') as from_url
    FROM moz_historyvisits v
    JOIN moz_places p ON v.place_id = p.id
    LEFT JOIN moz_historyvisits fv ON v.from_visit = fv.id
    LEFT JOIN moz_places fp ON fv.place_id = fp.id"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY v.visit_date DESC LIMIT $OPT_LIMIT;"

  echo "url${SEP}title${SEP}visit_time${SEP}transition${SEP}from_url"
  _query "$db" "$sql" "$SEP"
}

# Extract search keywords from Firefox input history.
#
# Output columns: input | url | title | use_count
#
# Options:
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
function searches {
  _parse_opts "$@"
  _output_setup "$OPT_FORMAT"
  local db
  db=$(_get_prepared_db) || return 1
  trap "rm -f '$db'" RETURN

  local sql="SELECT i.input, p.url, COALESCE(p.title, '') as title, i.use_count
    FROM moz_inputhistory i
    JOIN moz_places p ON i.place_id = p.id
    ORDER BY i.use_count DESC
    LIMIT $OPT_LIMIT;"

  echo "input${SEP}url${SEP}title${SEP}use_count"
  _query "$db" "$sql" "$SEP"
}

# Extract bookmarks from Firefox places database.
#
# Output columns: title | url | dateAdded | parent_title
#
# Options:
#   --limit, -n <number>     Max rows (default: 100)
#   --format <tsv|csv>       Output format (default: tsv)
function bookmarks {
  _parse_opts "$@"
  _output_setup "$OPT_FORMAT"
  local db
  db=$(_get_prepared_db) || return 1
  trap "rm -f '$db'" RETURN

  local sql="SELECT b.title, COALESCE(p.url, '') as url,
    datetime(b.dateAdded/1000000, 'unixepoch', 'localtime') as dateAdded,
    COALESCE(pb.title, '') as parent_title
    FROM moz_bookmarks b
    LEFT JOIN moz_places p ON b.fk = p.id
    LEFT JOIN moz_bookmarks pb ON b.parent = pb.id
    WHERE b.type = 1
    ORDER BY b.dateAdded DESC
    LIMIT $OPT_LIMIT;"

  echo "title${SEP}url${SEP}dateAdded${SEP}parent_title"
  _query "$db" "$sql" "$SEP"
}

# Show summary statistics for a given date range.
#
# Displays: total visits, unique URLs, top domains.
#
# Options:
#   --from, -f <YYYY-MM-DD>  Start date
#   --to, -t <YYYY-MM-DD>    End date
function summary {
  _parse_opts "$@"
  local db
  db=$(_get_prepared_db) || return 1
  trap "rm -f '$db'" RETURN

  local where=$(_build_firefox_date_filter "v.visit_date" "$OPT_FROM" "$OPT_TO") || return 1
  local where_clause=""
  [ -n "$where" ] && where_clause="WHERE $where"

  echo "=== ${BROWSER_NAME} History Summary ==="
  [ -n "$OPT_FROM" ] && echo "From: $OPT_FROM"
  [ -n "$OPT_TO" ] && echo "To: $OPT_TO"
  echo ""

  echo "--- Basic Stats ---"
  _query "$db" "SELECT
    COUNT(*) as total_visits,
    COUNT(DISTINCT v.place_id) as unique_urls
    FROM moz_historyvisits v $where_clause;" $'\t' | awk -F'\t' '{
    printf "Total visits:    %s\n", $1
    printf "Unique URLs:     %s\n", $2
  }'

  echo ""
  echo "--- Top 10 Domains ---"
  _query "$db" "SELECT
    REPLACE(REPLACE(SUBSTR(p.url, INSTR(p.url, '://') + 3), 'www.', ''),
      SUBSTR(REPLACE(SUBSTR(p.url, INSTR(p.url, '://') + 3), 'www.', ''),
        INSTR(REPLACE(SUBSTR(p.url, INSTR(p.url, '://') + 3), 'www.', ''), '/')), '') as domain,
    COUNT(*) as cnt
    FROM moz_historyvisits v
    JOIN moz_places p ON v.place_id = p.id
    $where_clause
    GROUP BY domain
    ORDER BY cnt DESC
    LIMIT 10;" $'\t' | awk -F'\t' '{printf "  %-40s %s visits\n", $1, $2}'

  echo ""
  echo "--- Visit Types ---"
  _query "$db" "SELECT
    CASE v.visit_type
      WHEN 1 THEN 'LINK'
      WHEN 2 THEN 'TYPED'
      WHEN 3 THEN 'BOOKMARK'
      WHEN 4 THEN 'EMBED'
      WHEN 5 THEN 'REDIRECT_PERM'
      WHEN 6 THEN 'REDIRECT_TEMP'
      WHEN 7 THEN 'DOWNLOAD'
      WHEN 8 THEN 'FRAMED_LINK'
      WHEN 9 THEN 'RELOAD'
      ELSE 'OTHER'
    END as type,
    COUNT(*) as cnt
    FROM moz_historyvisits v
    $where_clause
    GROUP BY type
    ORDER BY cnt DESC;" $'\t' | awk -F'\t' '{printf "  %-20s %s\n", $1, $2}'
}

cmd=$1
shift
case "$cmd" in
  help|-h|--help) help "$@" ;;
  urls) urls "$@"; exit $? ;;
  visits) visits "$@"; exit $? ;;
  searches) searches "$@"; exit $? ;;
  bookmarks) bookmarks "$@"; exit $? ;;
  summary) summary "$@"; exit $? ;;
  *) help ;;
esac
