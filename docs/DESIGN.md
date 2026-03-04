# Maho Notes — Design Document

> A personal knowledge base with beautiful markdown rendering, cross-platform native apps, vector search, and selective publishing.

## Overview

Maho Notes is a markdown-first knowledge management system designed for collaborative use between a human (Kuo-Chuan) and an AI assistant (Maho). It supports multiple collections, semantic search, and the ability to selectively publish notes as public web pages.

## Architecture

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  macOS App   │  │   iOS App    │  │   Web App    │
│  (SwiftUI)   │  │  (SwiftUI)   │  │  (Next.js)   │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       └────────────┬────┴────────┬────────┘
                    │             │
              ┌─────▼─────┐  ┌───▼────┐
              │ REST API   │  │  CLI   │
              │ (Backend)  │  │        │
              └─────┬──────┘  └───┬────┘
                    │             │
              ┌─────▼─────────────▼─────┐
              │      Core Library        │
              │  (Markdown, Search, Git) │
              └─────┬───────────────────┘
                    │
         ┌──────────┼──────────┐
         │          │          │
    ┌────▼───┐ ┌───▼────┐ ┌──▼───────┐
    │ GitHub │ │ SQLite  │ │ Embeddings│
    │ Repos  │ │ (meta)  │ │ (vector)  │
    └────────┘ └────────┘ └──────────┘
```

## Repositories

| Repo | Visibility | Content |
|------|-----------|---------|
| `kuochuanpan/maho-notes` | Public | App source code, CLI, web app, design docs |
| `kuochuanpan/maho-vault` | Private | Actual note content (markdown files) |

## Data Model

### Note (Markdown File)

Each note is a markdown file with YAML frontmatter:

```markdown
---
title: 訓讀 vs 音讀
collection: japanese
tags: [漢字, 読み方, N5]
created: 2026-03-03T09:18:00-05:00
updated: 2026-03-03T09:44:00-05:00
public: false
slug: kunyomi-vs-onyomi
author: maho
---

# 訓讀 vs 音讀

Content here...
```

### Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | string | ✅ | Display title |
| `collection` | string | ✅ | Collection id |
| `tags` | string[] | ❌ | Searchable tags |
| `created` | datetime | ✅ | Creation timestamp |
| `updated` | datetime | ✅ | Last modified |
| `public` | boolean | ❌ | If true, publishable as web page (default: false) |
| `slug` | string | ❌ | URL slug for published notes |
| `author` | string | ❌ | `maho` or `kuochuan` |
| `draft` | boolean | ❌ | Draft status (default: false) |
| `order` | number | ❌ | Sort order within collection |
| `series` | string | ❌ | Group notes into a series (e.g., "日語基礎") |

### Directory Structure (maho-vault)

```
maho-vault/
├── collections.yaml          # Collection definitions
├── japanese/                  # Collection: 日本語
│   ├── _index.md             # Collection overview
│   ├── vocabulary/
│   │   ├── 001-star.md
│   │   └── 002-universe.md
│   ├── grammar/
│   │   ├── 001-kunyomi-onyomi.md
│   │   ├── 002-long-vowels.md
│   │   └── 003-small-kana.md
│   └── conversation/
│       └── 001-shopping.md
├── astronomy/                 # Collection: 天文
│   ├── _index.md
│   └── ...
├── simulation/                # Collection: 模擬日誌
│   └── ...
├── software/                  # Collection: 軟體開發
│   └── ...
└── .maho/                     # Local metadata (gitignored)
    ├── index.db               # SQLite: metadata + FTS + vector embeddings
    └── cache/                 # Rendered HTML cache
```

### collections.yaml

```yaml
collections:
  - id: japanese
    name: 日本語
    icon: 🇯🇵
    description: 日語學習筆記 — 真帆老師的教材
  - id: astronomy
    name: 天文筆記
    icon: 🔭
    description: 天文物理研究筆記
  - id: simulation
    name: 模擬日誌
    icon: 💻
    description: 數值模擬運行紀錄與分析
  - id: software
    name: 軟體開發
    icon: ⚙️
    description: 程式設計與工具筆記
```

## Markdown Rendering

### Must Support
- **CommonMark + GFM** (tables, task lists, strikethrough, autolinks)
- **Syntax highlighting** — all major languages (Python, Swift, Rust, C++, Fortran, bash, JS/TS)
- **Math** — KaTeX (inline `$...$` and block `$$...$$`)
- **Diagrams** — Mermaid
- **Images** — local (relative path) + remote URL
- **Admonitions / callouts** — tip, warning, note, info blocks
- **Table of contents** — auto-generated from headings
- **Footnotes**
- **Furigana** — ruby annotation for Japanese (custom syntax or plugin)

### Rendering Stack
- **Native (SwiftUI)**: `swift-markdown` for parsing → custom `AttributedString` renderer, `WKWebView` fallback for complex content (KaTeX, Mermaid)
- **Web**: `unified` / `remark` / `rehype` pipeline with plugins
- **CLI**: terminal-friendly output (no rendering needed, just metadata + search results)

## CLI (`mn`)

```bash
# Note management
mn new "Title" --collection japanese --tags "N5,漢字"
mn edit japanese/grammar/001-kunyomi-onyomi.md
mn list --collection japanese
mn list --tag N5
mn show japanese/grammar/001-kunyomi-onyomi.md

# Search
mn search "長音規則"                    # full-text search
mn search --semantic "how do long vowels work"  # vector search

# Publishing
mn publish japanese/grammar/001-kunyomi-onyomi.md
mn unpublish japanese/grammar/001-kunyomi-onyomi.md

# Sync
mn sync                                 # git pull + push + reindex

# Index
mn index                                # rebuild SQLite + embeddings
mn index --collection japanese          # reindex one collection
```

## Vector Search

### Embedding Pipeline
1. On `mn index` or file change: parse markdown → extract text chunks (~500 tokens)
2. Generate embeddings (local model, e.g., `nomic-embed-text` or `all-MiniLM-L6-v2` via `mlx`)
3. Store in SQLite with `sqlite-vec` extension
4. Query: embed search string → cosine similarity → top-K results

### Search Modes
- **Full-text**: SQLite FTS5 on title + content + tags
- **Semantic**: Vector similarity search
- **Hybrid**: Combine FTS5 score + vector score with RRF (Reciprocal Rank Fusion)

## Native Apps (SwiftUI)

### Shared Codebase (macOS + iOS)
- **MahoNotesKit** — Swift package, shared logic:
  - Markdown parsing + rendering
  - Git operations (via `libgit2` or shell)
  - SQLite + vector search
  - Collection/note CRUD
- **MahoNotes-macOS** — macOS app target
- **MahoNotes-iOS** — iOS app target

### macOS App
- Sidebar: collections list
- Middle pane: note list (within collection)
- Main pane: markdown viewer / editor (split or toggle)
- Toolbar: search, new note, sync, publish toggle
- Keyboard shortcuts: Cmd+N (new), Cmd+S (save), Cmd+F (search), Cmd+Shift+F (global search)

### iOS App
- Tab bar or sidebar navigation (collections)
- Note list → tap to view
- Edit button to toggle editor
- Pull to sync
- Share sheet for publishing

### Editor
- Raw markdown editor with:
  - Syntax highlighting for markdown
  - Live preview (side-by-side on macOS, toggle on iOS)
  - Toolbar shortcuts (bold, italic, heading, link, image, code block)
  - Auto-save on pause

## Web App (Next.js)

### Routes
```
/                           → Dashboard (recent notes, collections)
/c/:collection              → Collection view
/c/:collection/:slug        → Note view
/c/:collection/:slug/edit   → Note editor
/search                     → Search page
/public/:collection/:slug   → Published note (no auth)
```

### Features
- SSR for published notes (SEO)
- Auth for private notes (GitHub OAuth or simple token)
- Monaco editor or CodeMirror for editing
- Responsive (serves as iOS fallback)

## Sync Strategy

### GitHub as Source of Truth
- All notes stored as markdown files in `maho-vault`
- Native apps + CLI do local git operations
- Conflict resolution: last-write-wins with backup of conflicting version
- Auto-sync: on app launch, on save (debounced), on app background (iOS)

### Offline Support
- Full local clone → works offline
- Queue changes → sync when online

## Publishing

### Flow
1. Set `public: true` + `slug` in frontmatter
2. `mn publish` or toggle in app
3. Web app serves published notes at `/public/:collection/:slug`
4. Optional: generate static HTML for hosting on GitHub Pages / Cloudflare Pages

### Features
- Custom domain support (e.g., `notes.pcca.dev`)
- RSS feed for published notes
- Open Graph meta tags for social sharing
- Reading time estimate

## Development Phases

### Phase 1 — Foundation (MVP)
- [ ] Vault directory structure + collections.yaml
- [ ] CLI tool (`mn`) — new, edit, list, show, search (FTS only)
- [ ] Git sync (pull/push)
- [ ] Web app — read-only viewer with nice rendering
- [ ] Populate initial Japanese notes from today's lessons

### Phase 2 — Search + Web Editor
- [ ] SQLite FTS5 index
- [ ] Vector embeddings + semantic search
- [ ] Web app editor (authenticated)
- [ ] Publishing (public notes as web pages)

### Phase 3 — macOS Native App
- [ ] SwiftUI app with sidebar + viewer
- [ ] Local git operations
- [ ] Markdown rendering (native + WKWebView hybrid)
- [ ] Editor with live preview

### Phase 4 — iOS App
- [ ] Shared SwiftUI codebase adaptation
- [ ] iCloud Keychain for git credentials
- [ ] Background sync
- [ ] Share extension (save to vault from Safari etc.)

### Phase 5 — Polish
- [ ] Furigana support
- [ ] Mermaid diagrams
- [ ] RSS + Open Graph for published notes
- [ ] Custom domain
- [ ] Export (PDF, EPUB)

## Tech Stack Summary

| Component | Technology |
|-----------|-----------|
| CLI | Swift (shares MahoNotesKit) |
| Web App | Next.js 15 + React + Tailwind |
| Native Apps | SwiftUI + MahoNotesKit (Swift Package) |
| Shared Logic | MahoNotesKit — markdown, search, git, CRUD |
| Markdown | remark/rehype (web), swift-markdown (native) |
| Syntax Highlighting | Shiki (web), TreeSitter (native) |
| Math | KaTeX (web), WKWebView + KaTeX (native) |
| Furigana | `{漢字|かんじ}` → `<ruby>` (web) / AttributedString (native) |
| Database | SQLite + FTS5 + sqlite-vec |
| Embeddings | BGE-M3 (1024d, multilingual 中英日, local via MLX) |
| Git | SwiftGit2 (macOS/CLI) / GitHub REST API (iOS) |
| Auth | GitHub OAuth (web) |
| Hosting | Cloudflare Pages or Vercel |
| Domain | notes.pcca.dev |

## Design Decisions

1. **CLI language**: **Swift** — shared codebase with native apps via MahoNotesKit Swift Package
2. **Git on iOS**: SwiftGit2 (libgit2) for macOS/CLI; GitHub REST API fallback for iOS
3. **Furigana syntax**: `{漢字|かんじ}` → renders to HTML `<ruby>` (web) / `AttributedString` ruby annotation (native)
4. **Embedding model**: **BGE-M3** (1024d, ~2.2GB) — best multilingual (中英日) support, runs locally on Mac mini via MLX
5. **Domain**: `notes.pcca.dev`

---

*Design by 真帆 🔭 — 2026-03-03*
