---
name: gws-workspace
description: "Google Workspace CLI operations via gws (Drive/Sheets/Docs/Slides/Calendar/Gmail). Use when a user asks to search, list, read, export, upload, or update files on Google Drive; read/write Google Sheets or Docs; manage Calendar events; send/search Gmail; or troubleshoot gws auth/access errors. Triggers: 'Google Drive', 'Sheets', 'Docs', 'Slides', 'gws', 'spreadsheet', 'ドライブ', 'スプレッドシート'. Do NOT use for: MCP-native Gmail/Calendar operations (prefer mcp__claude_ai_Gmail/Google_Calendar when available), local file operations, or non-Google cloud storage."
allowed-tools: [Read, Write, Bash, Grep, WebFetch, AskUserQuestion]
---

# Google Workspace CLI (gws)

## Prerequisites

1. `gws` must be on `$PATH` (`npm install -g @googleworkspace/cli`)
2. Auth: `gws auth login` (browser OAuth) or `GOOGLE_APPLICATION_CREDENTIALS` env var
3. Check auth: `NODE_NO_WARNINGS=1 gws auth status`

## Important

- **Always suppress Node warnings**: prefix commands with `NODE_NO_WARNINGS=1`
- **Read-only first**: always confirm access with a read command before writes
- **Confirm before writes**: never execute write/delete without user approval
- **Use `--dry-run`** for destructive operations
- **MCP fallback**: If `mcp__claude_ai_Gmail__*` or `mcp__claude_ai_Google_Calendar__*` tools are available, prefer those for Gmail/Calendar tasks

## Quick Reference

```bash
# Syntax
NODE_NO_WARNINGS=1 gws <service> <resource> <method> [flags]

# Inspect any method before calling
NODE_NO_WARNINGS=1 gws schema <service>.<resource>.<method>
```

## Core Services

<important if="working with Google Drive files, folders, uploads, downloads, or exports">
### Drive — files, folders, shared drives

```bash
# List files
gws drive files list --params '{"pageSize": 10}'

# Search
gws drive files list --params '{"q": "name contains '\''report'\''", "pageSize": 10}'

# Get file metadata
gws drive files get --params '{"fileId": "ID", "fields": "name,mimeType,size"}'

# Download
gws drive files get --params '{"fileId": "ID", "alt": "media"}' -o output.pdf

# Upload
gws drive +upload --file local.pdf --name "Report.pdf" --parent FOLDER_ID

# Export Google Doc as PDF
gws drive files export --params '{"fileId": "ID", "mimeType": "application/pdf"}' -o doc.pdf
```
</important>

<important if="reading or writing Google Sheets spreadsheet data">
### Sheets — read/write spreadsheets

```bash
# Read values
gws sheets +read --spreadsheet ID --range 'Sheet1!A1:D10'

# Read entire sheet
gws sheets +read --spreadsheet ID --range Sheet1

# Append row
gws sheets +append --spreadsheet ID --range 'Sheet1!A:D' --values '[["a","b","c","d"]]'

# Get spreadsheet metadata
gws sheets spreadsheets get --params '{"spreadsheetId": "ID"}'
```
</important>

<important if="reading or writing Google Docs documents">
### Docs — read/write documents

```bash
# Get doc metadata
gws docs documents get --params '{"documentId": "ID"}'

# Append text
gws docs +write --document ID --text "Appended text"
```
</important>

<important if="working with Google Slides presentations">
### Slides — presentations

```bash
# Get presentation
gws slides presentations get --params '{"presentationId": "ID"}'
```
</important>

<important if="sending or searching Gmail via gws CLI">
### Gmail

```bash
# List messages
gws gmail users messages list --params '{"userId": "me", "maxResults": 10}'

# Search
gws gmail users messages list --params '{"userId": "me", "q": "from:user@example.com"}'

# Send
gws gmail +send --to user@example.com --subject "Subject" --body "Body"
```
</important>

<important if="listing or creating Google Calendar events via gws CLI">
### Calendar

```bash
# List events
gws calendar events list --params '{"calendarId": "primary", "maxResults": 10}'

# Insert event
gws calendar +insert --calendar primary --summary "Meeting" --start "2026-03-12T10:00:00+09:00" --end "2026-03-12T11:00:00+09:00"
```
</important>

## Global Flags

| Flag | Description |
|------|-------------|
| `--format json\|table\|yaml\|csv` | Output format (default: json) |
| `--dry-run` | Validate without API call |
| `--page-all` | Auto-paginate (NDJSON) |
| `--page-limit N` | Max pages (default: 10) |

<important if="troubleshooting gws authentication or API errors">
## Error Handling

- **401/403**: Run `gws auth login` to re-authenticate
- **404**: Verify file/spreadsheet ID is correct
- **Rate limit**: Add `--page-delay 500` for bulk operations
</important>

## Discovery

```bash
# Browse all services
gws --help

# Browse service resources
gws drive --help

# Inspect method params
gws schema drive.files.list
```

For detailed API reference per service, see `references/` directory.
