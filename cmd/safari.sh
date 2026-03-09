#!/bin/bash
# Safari history subcommand (macOS only, Core Data timestamps)
VERSION=v0.2.0
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/../lib/common.sh"

BROWSER_NAME="Safari"
ENV_VAR="SAFARI_HISTORY_DB"

function _get_db_path {
  if [ -n "${SAFARI_HISTORY_DB}" ]; then
    echo "${SAFARI_HISTORY_DB}"
    return
  fi
  echo "$HOME/Library/Safari/History.db"
}

function _get_prepared_db {
  local db_path=$(_get_db_path)
  if [ "$(uname)" != "Darwin" ] && [ -z "${SAFARI_HISTORY_DB}" ]; then
    echo "Error: Safari is only available on macOS." >&2
    echo "Set ${ENV_VAR} env var if you have a Safari History.db file." >&2
    return 1
  fi
  local db
  db=$(_prepare_db "$db_path") || { echo "Set ${ENV_VAR} env var to specify the path." >&2; echo "Note: macOS Mojave+ requires Full Disk Access permission." >&2; return 1; }
  echo "$db"
}

# display help for safari subcommands.
function help {
  _subcmd_help "$0" "$VERSION" "$@"
}

# Extract visited URLs with title, visit count, and last visit time.
#
# Output columns: url | title | visit_count | last_visit_time
#
# Note: Safari requires Full Disk Access on macOS Mojave+.
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

  local where=$(_build_safari_date_filter "hi.visit_count_score" "$OPT_FROM" "$OPT_TO") || return 1
  # Safari uses visit_time in history_visits, for urls we filter via subquery
  local date_filter=""
  if [ -n "$OPT_FROM" ] || [ -n "$OPT_TO" ]; then
    local visit_where=$(_build_safari_date_filter "hv.visit_time" "$OPT_FROM" "$OPT_TO") || return 1
    if [ -n "$visit_where" ]; then
      date_filter="AND hi.id IN (SELECT hv.history_item FROM history_visits hv WHERE $visit_where)"
    fi
  fi

  local sql="SELECT hi.url, COALESCE(hv_title.title, '') as title, hi.visit_count,
    datetime(hi.visit_count_score + 978307200, 'unixepoch', 'localtime') as last_visit
    FROM history_items hi
    LEFT JOIN (
      SELECT history_item, title,
        ROW_NUMBER() OVER (PARTITION BY history_item ORDER BY visit_time DESC) as rn
      FROM history_visits WHERE title IS NOT NULL AND title != ''
    ) hv_title ON hi.id = hv_title.history_item AND hv_title.rn = 1
    WHERE hi.visit_count > 0 ${date_filter}
    ORDER BY hi.visit_count_score DESC
    LIMIT $OPT_LIMIT;"

  echo "url${SEP}title${SEP}visit_count${SEP}last_visit_time"
  _query "$db" "$sql" "$SEP"
}

# Extract individual visit records.
#
# Output columns: url | title | visit_time | redirect_source | redirect_destination
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

  local where=$(_build_safari_date_filter "hv.visit_time" "$OPT_FROM" "$OPT_TO") || return 1

  local sql="SELECT hi.url, COALESCE(hv.title, '') as title,
    datetime(hv.visit_time + 978307200, 'unixepoch', 'localtime') as visit_time,
    COALESCE(rs.url, '') as redirect_source,
    COALESCE(rd.url, '') as redirect_destination
    FROM history_visits hv
    JOIN history_items hi ON hv.history_item = hi.id
    LEFT JOIN history_visits rsv ON hv.redirect_source = rsv.id
    LEFT JOIN history_items rs ON rsv.history_item = rs.id
    LEFT JOIN history_visits rdv ON hv.redirect_destination = rdv.id
    LEFT JOIN history_items rd ON rdv.history_item = rd.id"
  [ -n "$where" ] && sql="$sql WHERE $where"
  sql="$sql ORDER BY hv.visit_time DESC LIMIT $OPT_LIMIT;"

  echo "url${SEP}title${SEP}visit_time${SEP}redirect_source${SEP}redirect_destination"
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

  local where=$(_build_safari_date_filter "hv.visit_time" "$OPT_FROM" "$OPT_TO") || return 1
  local where_clause=""
  [ -n "$where" ] && where_clause="WHERE $where"

  echo "=== ${BROWSER_NAME} History Summary ==="
  [ -n "$OPT_FROM" ] && echo "From: $OPT_FROM"
  [ -n "$OPT_TO" ] && echo "To: $OPT_TO"
  echo ""

  echo "--- Basic Stats ---"
  _query "$db" "SELECT
    COUNT(*) as total_visits,
    COUNT(DISTINCT hv.history_item) as unique_urls
    FROM history_visits hv $where_clause;" $'\t' | awk -F'\t' '{
    printf "Total visits:    %s\n", $1
    printf "Unique URLs:     %s\n", $2
  }'

  echo ""
  echo "--- Top 10 Domains ---"
  _query "$db" "SELECT
    REPLACE(REPLACE(SUBSTR(hi.url, INSTR(hi.url, '://') + 3), 'www.', ''),
      SUBSTR(REPLACE(SUBSTR(hi.url, INSTR(hi.url, '://') + 3), 'www.', ''),
        INSTR(REPLACE(SUBSTR(hi.url, INSTR(hi.url, '://') + 3), 'www.', ''), '/')), '') as domain,
    COUNT(*) as cnt
    FROM history_visits hv
    JOIN history_items hi ON hv.history_item = hi.id
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
  summary) summary "$@"; exit $? ;;
  *) help ;;
esac
