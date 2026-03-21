---
name: file-organizer
description: "Organizes files and folders by analyzing content, detecting duplicates, and restructuring directories. Use when the user says: 'organize my files', 'clean up downloads', 'find duplicates', 'restructure folder', 'organize photos', 'desktop cleanup', 'sort files', 'archive old projects', 'folder structure'. Handles Downloads cleanup, duplicate detection, project reorganization, and photo sorting. Do NOT use for code refactoring (use senior-fullstack), git operations, or codebase restructuring within a software project."
allowed-tools: [Read, Write, Bash, Glob, AskUserQuestion]
---

# File Organizer

Organize files and folders with analysis, duplicate detection, and automated cleanup.

## Workflow

### 1. Clarify Scope

Before touching any files, confirm with the user:
- Target directory (Downloads, Documents, Projects, etc.)
- Goal (find duplicates, restructure, archive old files)
- Files/folders to exclude (active projects, sensitive data)
- Aggressiveness (conservative sort vs. comprehensive cleanup)

### 2. Analyze Current State

```bash
ls -la [target_directory]
du -sh [target_directory]/* | sort -rh | head -20
```

Summarize: total files, file type breakdown, size distribution, obvious issues.

<important if="finding duplicate files or cleaning up redundant copies">

### 3. Detect Duplicates (When Requested)

```bash
# Find exact duplicates by hash
find [directory] -type f -exec md5 {} \; | sort | uniq -d
```

For each duplicate set, show:
- All file paths with sizes and modification dates
- Recommendation on which to keep (newest or best-named)

**CRITICAL: Always ask for confirmation before deleting any file.**

</important>

<important if="proposing a file organization plan or restructuring a directory">

### 4. Propose Organization Plan

Present the plan as a structured summary before executing:

```
Current: X files across Y folders, Z GB total
Proposed structure:
  [Directory tree]
Changes:
  - Create: [new folders]
  - Move: [file counts per destination]
  - Rename: [patterns]
  - Delete: [duplicates/trash, with user approval]
Files needing your decision: [list unclear items]
```

Wait for explicit approval before proceeding.

</important>

<important if="executing file moves, renames, or deletions during cleanup">

### 5. Execute

```bash
mkdir -p "path/to/new/folders"
mv "old/path/file.pdf" "new/path/file.pdf"
```

Rules:
- **Never delete without confirmation**
- Log all moves for potential undo
- Preserve original modification dates
- Handle filename conflicts (append suffix, never overwrite)
- Stop and ask if anything unexpected occurs

</important>

### 6. Report Results

After completion, provide:
- Files organized count
- Space freed (if duplicates removed)
- New folder structure tree
- Maintenance tips (weekly sort, monthly archive review)

<important if="organizing Downloads folder or cleaning up desktop files">

## Common Patterns

| Task | Suggested Structure |
|------|-------------------|
| Downloads cleanup | Work/, Personal/, Installers/, Archive/, ToSort/ |
| Photo organization | YYYY/MM-MonthName/ (based on EXIF or mtime) |
| Project restructure | Active/, Archive/YYYY/, Templates/ |
| Desktop cleanup | Move everything to Documents/ with proper categorization |

</important>

<important if="renaming files or standardizing file naming conventions">

## Naming Conventions

- Files: `YYYY-MM-DD-description.ext` for dated files
- Folders: lowercase with hyphens (`client-proposals`, not `Client Proposals`)
- Remove download artifacts: `doc-final-v2 (1).pdf` to `doc.pdf`

</important>

## Error Handling

- If permission denied: inform user which files need elevated permissions
- If disk full during moves: stop, report progress so far, suggest freeing space first
- If filename conflict: append `-1`, `-2` suffix, never silently overwrite
- If EXIF data unavailable for photos: fall back to file modification date
- If target directory does not exist: create it with `mkdir -p`, do not fail silently
