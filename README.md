# chrome-history-cli

CLI tool to extract Google Chrome browsing history data via SQLite.

Built on [cli.sh](https://github.com/tk-aria/cli.sh) framework pattern.

## Requirements

- `bash`
- `sqlite3`

## Install

```bash
git clone https://github.com/tk-aria/chrome-history-cli.git
cd chrome-history-cli
chmod +x chrome-history.sh
```

## Usage

```bash
./chrome-history.sh <command> [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `urls` | URL list (title, visit count, typed count, last visit time) |
| `visits` | Individual visit records (duration, transition type, referrer URL) |
| `searches` | Search keywords |
| `downloads` | Download history (path, size, MIME type, status) |
| `annotations` | Content annotations (page category, language, search terms) |
| `contexts` | Context annotations (foreground duration, response code) |
| `summary` | Summary statistics (total visits, top domains, total time) |
| `fzf` | Interactive command selection with fzf |

### Common Options

```
--from, -f <YYYY-MM-DD>    Start date (inclusive)
--to, -t <YYYY-MM-DD>      End date (inclusive)
--limit, -n <number>       Max rows (default: 100)
--format <tsv|csv>         Output format (default: tsv)
```

### Examples

```bash
# List URLs visited in the last week (CSV)
./chrome-history.sh urls -f 2026-03-02 -t 2026-03-09 --format csv

# Pipe-friendly: extract visit times and URLs
./chrome-history.sh visits --format csv | awk -F, 'NR>1{print $3, $1}'

# Search keywords
./chrome-history.sh searches -f 2026-03-01

# Summary statistics
./chrome-history.sh summary -f 2026-03-01 -t 2026-03-09

# Top 10 most visited URLs
./chrome-history.sh urls -n 10

# Download history as CSV
./chrome-history.sh downloads --format csv > downloads.csv
```

### Custom Chrome History DB Path

By default, the tool auto-detects the Chrome history DB path based on the OS:
- **macOS**: `~/Library/Application Support/Google/Chrome/Default/History`
- **Linux**: `~/.config/google-chrome/Default/History`
- **Windows** (Git Bash): `%LOCALAPPDATA%/Google/Chrome/User Data/Default/History`

Override with the `CHROME_HISTORY_DB` environment variable:

```bash
export CHROME_HISTORY_DB="/path/to/your/History"
./chrome-history.sh urls
```

## Output Format

- Default: TSV (tab-separated) — ideal for `awk` processing
- Optional: CSV with `--format csv` — ideal for spreadsheets and `read` loops
- First line is always a header row

```bash
# Process with awk
./chrome-history.sh urls | awk -F'\t' 'NR>1{print $3, $1}'

# Process with read
./chrome-history.sh urls --format csv | while IFS=',' read -r url title count typed last; do
  echo "URL: $url (visited $count times)"
done
```

## License

MIT
