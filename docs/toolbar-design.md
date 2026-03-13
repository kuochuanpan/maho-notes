# Markdown Formatting Toolbar — Design Document

> Date: 2026-03-13
> Status: Phase 1 in progress

## Overview

A formatting toolbar for the markdown editor in Maho Notes, providing quick access to common markdown syntax operations across all platforms (macOS, iPadOS, iPhone).

## Platform Layout

### macOS & iPad (landscape)
- Toolbar buttons placed in the **breadcrumb bar** (C panel), right-aligned
- Icon-only buttons to save space
- Overflow into `[+]` Menu when space is tight

### iPad (edit/split mode)
- **Top bar**: full toolbar (same as macOS)
- **Keyboard accessory**: compact version (same as iPhone) when keyboard is active

### iPhone
- **Keyboard accessory bar**: floating above keyboard during editing
- Compact: 5 常用 buttons + `···` (More) + `⌄` (dismiss keyboard)
- Layout: `[ B ] [ I ] [ H ] [ ☑ ] [ - ] [ ··· ] [ ⌄ ]`

## Toolbar Actions

### Text Formatting (wrap selection or insert placeholder)

| Action | Syntax | With selection `hello` | Without selection (│ = cursor) |
|--------|--------|----------------------|-------------------------------|
| Bold | `**` | `**hello**` | `**│**` |
| Italic | `*` | `*hello*` | `*│*` |
| Strikethrough | `~~` | `~~hello~~` | `~~│~~` |
| Inline Code | `` ` `` | `` `hello` `` | `` `│` `` |
| Link | `[]()` | `[hello](│)` | `[│](url)` |
| Ruby | `{漢字\|reading}` | `{hello\|│}` | `{│\|reading}` |

### Line Prefix (toggle at line start)

| Action | Syntax | Behavior |
|--------|--------|----------|
| Heading | `#` | Cycle: `# ` → `## ` → `### ` → remove |
| Quote | `>` | Toggle `> ` prefix |
| Bullet List | `-` | Toggle `- ` prefix |
| Numbered List | `1.` | Toggle `1. ` prefix (via long press on List) |
| Checkbox | `- [ ]` | Toggle `- [ ] ` prefix |

### Insert Actions

| Action | Behavior |
|--------|----------|
| Table | Open M×N picker sheet → insert empty markdown table |
| Insert Photo | File picker → copy to `_assets/` → insert `![name\|center\|50%](_assets/file.png)` |
| Insert File | File picker → copy to `_assets/` → insert `[name](_assets/file.pdf)` |

## Image Syntax

Extended markdown image syntax:
```
![alt | alignment | width](relative_path)
```

- `alignment`: `left` | `center` | `right` (default: `center`)
- `width`: `25%` | `50%` | `75%` | `100%` (default: `100%`)
- All parameters optional: `![photo](path)` is valid

## Asset Storage (方案 A: collection-local `_assets/`)

```
vault/
├── japanese/grammar/
│   ├── particles.md        → ![diagram](_assets/diagram.png)
│   ├── keigo.md
│   └── _assets/
│       ├── diagram.png
│       └── table.pdf
└── _assets/                 ← vault-level (optional)
```

### Asset Management Rules

- **Insert**: Store in note's directory `_assets/` (auto-create if missing)
- **Move Note**: Scan referenced assets → move/copy to target `_assets/`
- **Copy Note**: Always copy referenced assets
- **Move Collection**: `_assets/` travels with directory (no special handling needed)
- **Delete Note**: Optionally clean orphan assets

## Implementation Phases

### Phase 1: Foundation + Basic Formatting
1. `MarkdownToolbarAction` enum
2. `MarkdownTextHelper` — text insertion/wrapping logic
3. Replace `TextEditor` with `UITextView`/`NSTextView` wrapper (for `selectedRange` access)
4. macOS breadcrumb bar toolbar (Bold, Italic, Strikethrough, Heading)
5. iPhone keyboard accessory (compact 5 + More)

### Phase 2: All Text Formatting Actions
- Code, Quote, List, Checkbox, Link, Heading cycle, Ruby

### Phase 3: `_assets/` Infrastructure
- `AssetManager`, update `moveNote`/`moveCollection`, add `copyNote`

### Phase 4: Insert Photo & File
- Platform file pickers + asset import + markdown insertion

### Phase 5: Table Picker
- M×N grid picker + table generation

### Phase 6: Polish & Platform Parity
- iPad dual toolbar, overflow menu, keyboard shortcuts, accessibility

## Keyboard Shortcuts (macOS / iPad external keyboard)

| Shortcut | Action |
|----------|--------|
| ⌘B | Bold |
| ⌘I | Italic |
| ⌘K | Link |
| ⌘⇧X | Strikethrough |
| ⌘⇧C | Inline Code |
