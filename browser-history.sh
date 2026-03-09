#!/bin/bash
VERSION=v0.2.0

# directories to search for subcommands
CMD_DIRS=("cmd")

# display help information for all available browser commands.
# use --brief to show only command descriptions without header.
function help {
  local brief=false
  if [ "$1" = "--brief" ]; then
    brief=true
  fi

  local cmd=$(cmd=$(basename $0); echo "${cmd%.*}")
  local scriptDir=$(cd "$(dirname "$0")" && pwd)

  # ANSI color codes
  local PURPLE=$'\033[35m'
  local CYAN=$'\033[36m'
  local GREEN=$'\033[32m'
  local BRIGHT_GREEN=$'\033[92m'
  local RESET=$'\033[0m'

  if [ "$brief" = false ]; then
    read -d '' header <<-EOF
${PURPLE}${cmd}${RESET} (${CYAN}${VERSION}${RESET})

Usage: ${PURPLE}$0${RESET} <${GREEN}browser${RESET}> <${BRIGHT_GREEN}command${RESET}> [options]

Browsers:
  ${GREEN}chrome${RESET}    Google Chrome / Chromium
  ${GREEN}edge${RESET}      Microsoft Edge
  ${GREEN}firefox${RESET}   Mozilla Firefox
  ${GREEN}safari${RESET}    Apple Safari (macOS only)

Common Options:
  --from, -f <YYYY-MM-DD>    Start date (inclusive)
  --to, -t <YYYY-MM-DD>      End date (inclusive)
  --limit, -n <number>       Max rows (default: 100)
  --format <tsv|csv>         Output format (default: tsv)

Examples:
  $0 chrome urls -f 2026-03-01 --format csv
  $0 firefox visits -f 2026-03-01 -t 2026-03-09
  $0 edge searches -n 50
  $0 safari summary -f 2026-03-01
  $0 chrome downloads --format csv > downloads.csv
EOF
    echo -e "$header"
  fi

  # show help for subcommands in configured directories
  for cmdDir in "${CMD_DIRS[@]}"; do
    local fullPath="${scriptDir}/${cmdDir}"
    if [ -d "$fullPath" ]; then
      for subCmd in "${fullPath}"/*.sh; do
        if [ -f "$subCmd" ]; then
          local subCmdName=$(basename "$subCmd" .sh)
          echo -e "\n${GREEN}${subCmdName}${RESET}:"
          "$subCmd" help --brief 2>/dev/null | sed 's/^/  /' || echo "  (no help available)"
        fi
      done
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

# select browser and command interactively with fzf.
function fzf {
  local scriptDir=$(cd "$(dirname "$0")" && pwd)
  local browsers=""
  for cmdDir in "${CMD_DIRS[@]}"; do
    local fullPath="${scriptDir}/${cmdDir}"
    if [ -d "$fullPath" ]; then
      for subCmd in "${fullPath}"/*.sh; do
        if [ -f "$subCmd" ]; then
          browsers="${browsers}$(basename "$subCmd" .sh)\n"
        fi
      done
    fi
  done
  local selected_browser=$(echo -e "$browsers" | command fzf --prompt="Select browser: ")
  if [ -n "$selected_browser" ]; then
    $0 "$selected_browser" "$@"
  fi
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

  *)
    # check if subcommand exists in configured directories
    for cmdDir in "${CMD_DIRS[@]}"; do
      if [ -f "${SCRIPT_DIR}/${cmdDir}/${cmd}.sh" ]; then
        "${SCRIPT_DIR}/${cmdDir}/${cmd}.sh" "$@"
        exit $?
      fi
    done
    help
    ;;
esac
