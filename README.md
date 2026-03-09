# browser-history-cli

CLI tool to extract browsing history from multiple browsers via SQLite.

Supports: **Chrome**, **Edge**, **Firefox**, **Safari**

Built on [cli.sh](https://github.com/tk-aria/cli.sh) framework pattern.

## Requirements

- `bash`
- `sqlite3`

## Install

```bash
git clone https://github.com/tk-aria/chrome-history-cli.git
cd chrome-history-cli
chmod +x browser-history.sh cmd/*.sh
```

## Usage

```bash
./browser-history.sh <browser> <command> [options]
```

### Supported Browsers

| Browser | Subcommand | DB Format |
|---------|-----------|-----------|
| Google Chrome | `chrome` | Chromium SQLite (WebKit timestamp) |
| Microsoft Edge | `edge` | Chromium SQLite (same as Chrome) |
| Mozilla Firefox | `firefox` | Mozilla places.sqlite (PRTime) |
| Apple Safari | `safari` | Core Data SQLite (macOS only) |

### Commands by Browser

| Command | Chrome | Edge | Firefox | Safari |
|---------|--------|------|---------|--------|
| `urls` | Yes | Yes | Yes | Yes |
| `visits` | Yes | Yes | Yes | Yes |
| `searches` | Yes | Yes | Yes | - |
| `downloads` | Yes | Yes | - | - |
| `annotations` | Yes | - | - | - |
| `contexts` | Yes | - | - | - |
| `bookmarks` | - | - | Yes | - |
| `summary` | Yes | Yes | Yes | Yes |

### Common Options

```
--from, -f <YYYY-MM-DD>    Start date (inclusive)
--to, -t <YYYY-MM-DD>      End date (inclusive)
--limit, -n <number>       Max rows (default: 100)
--format <tsv|csv>         Output format (default: tsv)
```

### Examples

```bash
# Chrome: List URLs visited in the last week (CSV)
./browser-history.sh chrome urls -f 2026-03-02 -t 2026-03-09 --format csv

# Edge: Search keywords
./browser-history.sh edge searches -n 50

# Firefox: Visit records with transition tracking
./browser-history.sh firefox visits -f 2026-03-01 -t 2026-03-09

# Firefox: Bookmarks
./browser-history.sh firefox bookmarks --format csv

# Safari: Summary statistics
./browser-history.sh safari summary -f 2026-03-01

# Pipe-friendly: extract with awk
./browser-history.sh chrome visits --format csv | awk -F, 'NR>1{print $3, $1}'

# Pipe-friendly: process with read
./browser-history.sh firefox urls --format csv | while IFS=',' read -r url title count last; do
  echo "$title ($count visits)"
done
```

### Custom DB Path

Override auto-detected paths with environment variables:

```bash
export CHROME_HISTORY_DB="/path/to/History"
export EDGE_HISTORY_DB="/path/to/History"
export FIREFOX_HISTORY_DB="/path/to/places.sqlite"
export SAFARI_HISTORY_DB="/path/to/History.db"
```

### Default DB Paths

**Chrome:**
- macOS: `~/Library/Application Support/Google/Chrome/Default/History`
- Linux: `~/.config/google-chrome/Default/History`
- Windows: `%LOCALAPPDATA%/Google/Chrome/User Data/Default/History`

**Edge:**
- macOS: `~/Library/Application Support/Microsoft Edge/Default/History`
- Linux: `~/.config/microsoft-edge/Default/History`
- Windows: `%LOCALAPPDATA%/Microsoft/Edge/User Data/Default/History`

**Firefox:**
- macOS: `~/Library/Application Support/Firefox/Profiles/*.default-release/places.sqlite`
- Linux: `~/.mozilla/firefox/*.default-release/places.sqlite`
- Windows: `%APPDATA%/Mozilla/Firefox/Profiles/*.default-release/places.sqlite`

**Safari:**
- macOS: `~/Library/Safari/History.db` (requires Full Disk Access)

## Architecture

```
browser-history.sh          # Main CLI entry point (router)
├── cmd/
│   ├── chrome.sh           # Chrome subcommand (Chromium schema)
│   ├── edge.sh             # Edge subcommand (Chromium schema)
│   ├── firefox.sh          # Firefox subcommand (Mozilla schema)
│   └── safari.sh           # Safari subcommand (Core Data schema)
└── lib/
    └── common.sh           # Shared helpers (DB copy, date filters, query)
```

## Output Format

- Default: TSV (tab-separated) for `awk` processing
- Optional: CSV with `--format csv` for spreadsheets and `read` loops
- First line is always a header row

## Legacy

The original `chrome-history.sh` (single-browser version) is still available for backwards compatibility.

## License

MIT
