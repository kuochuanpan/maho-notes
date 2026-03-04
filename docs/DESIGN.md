# Maho Notes — Design Document

> A multilingual personal knowledge base with beautiful markdown rendering, cross-platform native apps, on-device vector search, and selective publishing.

## Overview

Maho Notes is a markdown-first knowledge management system with first-class support for **Chinese (中文)**, **English**, and **Japanese (日本語)**. It supports multiple collections, on-device multilingual semantic search, and the ability to selectively publish notes as public web pages via GitHub Pages. Works offline, syncs via iCloud, and optionally integrates with GitHub for version control and publishing.

### Multilingual Support 🌐
- **UI**: Chinese, English, Japanese (user-selectable)
- **Content**: Full Unicode support, mixed-language notes
- **Search**: FTS5 + vector search work across all three languages
- **Furigana**: Native `{漢字|かんじ}` rendering for Japanese learners
- **Embedding models**: All tiers support 中英日 multilingual semantic search

## Architecture

```
┌──────────────────────────┐  ┌──────────┐
│   Universal App (SwiftUI) │  │   CLI    │
│   macOS + iOS             │  │  (mn)    │
└──────────┬───────────────┘  └────┬─────┘
           │                       │
     ┌─────▼───────────────────────▼─────┐
     │         MahoNotesKit              │
     │  (Markdown, Search, CRUD, Sync)   │
     └──┬──────────┬──────────┬──────────┘
        │          │          │
   ┌────▼───┐ ┌───▼────┐ ┌──▼───────┐
   │ iCloud  │ │ SQLite  │ │Embeddings│
   │ / Git   │ │ (FTS+vec)│ │(on-device)│
   └────────┘ └────────┘ └──────────┘

Publishing (optional):
   App → generates static HTML → pushes to user's GitHub repo → GitHub Pages
```

## Repositories (Our Instance)

| Repo | Visibility | Content |
|------|-----------|---------|
| `kuochuanpan/maho-notes` | Public | App source code, CLI, design docs (open source) |
| `kuochuanpan/maho-vault` | Private | Our note content (other users create their own vault) |

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

The CLI is a first-class interface — not just for humans, but for AI agents.
It must support full CRUD, search, and publishing with scriptable (JSON) output.

```bash
# ── CRUD ──────────────────────────────────────────
mn new "Title" --collection japanese --tags "N5,漢字"
mn edit <path>                        # open in $EDITOR
mn write <path> --content "..."       # write body directly (AI agent use)
mn write <path> --file input.md       # write body from file
mn append <path> --content "..."      # append to existing note
mn delete <path>                      # move to trash / confirm
mn move <path> --to <collection/dir>  # move note

# ── Read ──────────────────────────────────────────
mn show <path>                        # display note with metadata
mn show <path> --body-only            # content only (for piping)
mn list                               # all notes, grouped by collection
mn list --collection japanese         # filter by collection
mn list --tag N5                      # filter by tag
mn list --series "日語基礎"            # filter by series

# ── Metadata ──────────────────────────────────────
mn meta <path>                        # show frontmatter
mn meta <path> --set public=true      # update frontmatter field
mn meta <path> --add-tag "grammar"    # add tag
mn meta <path> --remove-tag "draft"   # remove tag
mn meta <path> --set series="日語基礎" # set series

# ── Search ────────────────────────────────────────
mn search "長音規則"                    # full-text search (FTS5)
mn search --semantic "how do vowels work"  # vector search
mn search --tag N5                    # search by tag
mn search --collection japanese "query"    # scoped search
mn search --semantic "query" --limit 5     # top-K results

# ── Publishing ────────────────────────────────────
mn publish                            # publish all public notes
mn publish <path>                     # publish single note
mn unpublish <path>                   # remove from published site
mn publish --preview                  # local preview before push

# ── Sync & Index ──────────────────────────────────
mn sync                               # git pull + push + reindex
mn index                              # rebuild SQLite + embeddings
mn index --model bge-m3               # specify embedding model
mn index --collection japanese        # reindex one collection

# ── Info ──────────────────────────────────────────
mn collections                        # list all collections
mn stats                              # note count, word count, per-collection stats

# ── AI Agent / Scripting ──────────────────────────
mn list --json                        # JSON output for all commands
mn show <path> --json                 # JSON output
mn search "query" --json              # JSON output
mn batch < commands.jsonl             # batch execute from JSONL
```

### Global Flags
| Flag | Description |
|------|-------------|
| `--vault <path>` | Vault path (default: `~/maho-vault` or `$MN_VAULT`) |
| `--json` | Machine-readable JSON output (for AI agents / scripts) |
| `--quiet` | Suppress non-essential output |
| `--verbose` | Debug output |

## Vector Search

### Architecture
- **100% on-device** — no server dependency (App Store requirement)
- Each device has its own local embedding DB (not synced between devices)
- Markdown files sync via iCloud/GitHub; each device generates its own embeddings locally
- User can choose embedding model per device (bigger Mac → bigger model, iPhone → smaller model)

### Embedding Models (User-Selectable)

| Tier | Model | Size | Dim | Quality | Platforms |
|------|-------|------|-----|---------|-----------|
| 🟢 Built-in | Apple NLEmbedding | 0 MB | varies | Basic | All (iOS 17+, macOS 14+) |
| 🟡 Light | all-MiniLM-L6-v2 (multilingual) | ~90 MB | 384 | Good | All |
| 🟠 Standard | multilingual-e5-small | ~470 MB | 384 | Better | All |
| 🔴 Pro | BGE-M3 | ~2.2 GB | 1024 | Best | Mac recommended |

- **Default**: Apple NLEmbedding (zero download, works immediately)
- **Optional**: User downloads preferred model in Settings → Search → Embedding Model
- **Per-device choice**: iPhone can use Light, Mac can use Pro — independent
- Models distributed as CoreML packages (downloadable from app or bundled)

### Embedding Pipeline (Per Device)
1. Note created/updated → markdown syncs to device via iCloud/GitHub
2. Device detects new/changed notes → queues for local embedding
3. Background task runs selected model → generates embeddings
4. Stored in local SQLite (sqlite-vec) — **not synced** (each device has its own)
5. Query: embed search string locally → cosine similarity → top-K results

### Why Not Sync Embeddings?
- Different devices may use different models (different dimensions)
- Embedding DB can be regenerated from markdown anytime
- Avoids syncing large binary blobs
- Each device optimizes for its own hardware

### Search Modes
- **Full-text**: SQLite FTS5 on title + content + tags (always available, instant)
- **Semantic**: Vector similarity search (available after local indexing)
- **Hybrid**: Combine FTS5 score + vector score with RRF (Reciprocal Rank Fusion)

### CLI (`mn index`)
- CLI uses same model selection: `mn index --model bge-m3` or `mn index --model builtin`
- Can also use MLX directly for BGE-M3 (faster on Apple Silicon than CoreML for large models)

## Native App (Universal, SwiftUI)

One Xcode project, shared SwiftUI codebase. Supports **macOS**, **iOS**, and **iPadOS**.

### MahoNotesKit (Swift Package — Shared Logic)
- Markdown parsing + rendering
- iCloud sync (primary) + Git operations (optional, for CLI/publishing)
- SQLite + FTS5 + sqlite-vec (vector search)
- On-device embedding (CoreML / NLEmbedding)
- Collection/note CRUD
- Static site generator (for publishing)

### Platform Adaptation (NavigationSplitView)

| Platform | Layout | Notes |
|----------|--------|-------|
| **macOS** | Three-column sidebar | Split-pane editor (markdown + live preview) |
| **iPadOS** | Two/three-column split view | Stage Manager multi-window, keyboard shortcuts, Apple Pencil (future) |
| **iPhone** | Single-column push navigation | Compact UI, toggle view/edit |

### macOS
- Split-pane editor (markdown + live preview side by side)
- Keyboard shortcuts: Cmd+N (new), Cmd+S (save), Cmd+F (search), Cmd+Shift+F (global search)

### iPadOS
- Split view like macOS (landscape) / push navigation (portrait)
- Keyboard shortcuts (same as macOS when external keyboard connected)
- Drag & drop support
- Stage Manager: multiple windows

### iPhone
- Push navigation, compact layout
- Toggle between view/edit mode
- Pull to sync
- Share sheet for publishing

### Editor (Shared)
- Raw markdown editor with:
  - Syntax highlighting for markdown
  - Live preview (side-by-side on macOS, toggle on iOS)
  - Toolbar shortcuts (bold, italic, heading, link, image, code block)
  - Auto-save on pause

## Web (Published Sites via GitHub Pages)

No centralized web app. Publishing generates a static site deployed to the user's own GitHub Pages.

### What the App Generates
- Static HTML/CSS/JS from `public: true` notes
- Deployed to user's GitHub repo → served by GitHub Pages
- Clean theme with light/dark mode

### Published Site Routes (per user)
```
/                           → Index (list of published collections + notes)
/c/:collection              → Collection page
/c/:collection/:slug        → Published note
/feed.xml                   → RSS feed
```

### Features
- Beautiful rendering (syntax highlighting, KaTeX, Mermaid, furigana)
- Responsive design
- RSS feed, Open Graph meta tags
- Custom domain support (user configures in GitHub Pages settings)
- SEO-friendly static HTML

## Sync Strategy

### Multi-Backend Storage
App must work standalone (App Store requirement). iCloud is default; GitHub is optional.

| Backend | Use Case | Platforms |
|---------|----------|-----------|
| **Local only** | Default, App Store friendly | macOS, iPadOS, iOS |
| **iCloud** | Seamless Apple device sync, zero config | macOS, iPadOS, iOS |
| **GitHub** | Cross-Apple-ID sync, version control, collaboration, publishing | All |

### Sync Modes

#### Mode 1: iCloud Only (Default)
For most users. Zero config, just works.
```
iPhone ←──iCloud──→ iPad ←──iCloud──→ Mac
         (same Apple ID)
```

#### Mode 2: iCloud + GitHub (Power User / Cross-Apple-ID)
Enable GitHub sync in Settings. GitHub acts as a bridge between different Apple IDs or between human and AI agent.

```
Apple ID A                   GitHub                Apple ID B
┌──────────┐   auto sync    ┌────────┐  auto sync  ┌──────────┐
│ Device A │ ←────────────→ │  repo  │ ←─────────→ │ Device B │
│ (iCloud A)│               │        │              │ (iCloud B)│
└──────────┘               └────────┘   iCloud     └─────┬────┘
                                         sync       ┌────▼────┐
                                                     │Device B2│
                                                     │(iCloud B)│
                                                     └─────────┘
```

Real-world example (our setup):
- Maho (Mac mini, Apple ID A) → writes notes via CLI → auto push to GitHub
- GitHub repo → auto pull to Kuo-Chuan's MacBook (Apple ID B)
- MacBook iCloud → syncs to Kuo-Chuan's iPhone/iPad

#### GitHub Sync Behavior (When Enabled)
- **Auto push**: On note save, debounced (e.g., 30s after last edit)
- **Auto pull**: On app launch + periodic (e.g., every 5 min) + pull-to-refresh
- **Conflict resolution**: 
  - Same file edited on both sides → keep both versions (`.conflict` suffix)
  - Notify user to resolve manually
  - iCloud conflicts use NSFileVersion (automatic)
- **What syncs**: Only markdown files + collections.yaml + assets
- **What doesn't sync**: `.maho/` (local DB, embeddings, cache)

### Import from GitHub
One-time import for new devices or switching from CLI-only workflow:
```bash
mn import --from https://github.com/user/vault.git
```
In app: Settings → Sync → Import from GitHub Repository

### Offline Support
- Full local storage → always works offline
- iCloud: automatic background sync when online
- GitHub: queues changes, syncs when online

## Publishing

### Philosophy
Maho Notes is a **tool, not a platform**. We don't host anyone's content.
Each user publishes to their own GitHub Pages (or other static hosting).

### Architecture
```
User's App                    User's GitHub
┌──────────┐    generate     ┌─────────────────┐    GitHub Pages
│ Markdown │ ──────────────→ │ user/my-notes    │ ──────────────→ user.github.io/my-notes
│ (public) │   static HTML   │ (public repo)    │                 or custom domain
└──────────┘                 └─────────────────┘
```

### Flow (All Platforms)
1. User connects GitHub account in Settings (OAuth via `ASWebAuthenticationSession` on iOS/macOS)
2. User creates/selects a GitHub repo for publishing (e.g., `user/my-notes`)
3. Mark notes as `public: true` + set `slug` in frontmatter
4. Tap "Publish" → app generates static HTML + pushes to user's repo
5. GitHub Pages serves the site automatically

### Publishing by Platform

| Platform | Auth | Push Method |
|----------|------|-------------|
| iOS | `ASWebAuthenticationSession` (system browser) | GitHub REST API |
| macOS | `ASWebAuthenticationSession` | GitHub REST API or git |
| CLI | `gh auth` or token | git push |

All platforms can publish. No git CLI needed on iOS — pure HTTP API.

### What Gets Published
- Only notes with `public: true` in frontmatter
- Static HTML with beautiful rendering (syntax highlighting, KaTeX, furigana)
- Auto-generated index page, collection pages, RSS feed
- User's private notes never leave their device/iCloud

### User Setup (One-Time)
1. In app: Settings → Publishing → Connect GitHub
2. Create or select a repo (app can create it for the user)
3. Enable GitHub Pages in repo settings (app guides the user)
4. Optional: configure custom domain (e.g., `notes.alice.dev`)

### CLI
```bash
mn publish                          # generate + push all public notes
mn publish japanese/grammar/001-kunyomi-onyomi.md  # publish single note
mn unpublish <path>                 # remove from published site
mn publish --preview                # local preview before pushing
```

### Static Site Features
- Clean, responsive theme (light/dark mode)
- Syntax highlighting, KaTeX math, Mermaid diagrams, furigana
- Collection-based navigation
- RSS feed
- Open Graph meta tags for social sharing
- Reading time estimate
- Customizable theme (future: user-selectable themes)

### Our Instance
- `notes.pcca.dev` → Kuo-Chuan's personal published notes (our own GitHub Pages)
- Not a shared platform — just our own deployment of the same tool

## Development Phases

### Phase 1 — Foundation (MVP) ← current
- [x] Vault directory structure + collections.yaml
- [x] CLI tool (`mn`) — new, list, show, search (basic text)
- [x] Initial Japanese notes populated
- [ ] CLI: edit, sync (git pull/push)
- [ ] SQLite FTS5 index for faster search

### Phase 2 — Universal App (macOS + iOS)
- [ ] Xcode project with macOS + iOS targets
- [ ] SwiftUI: NavigationSplitView (collections → notes → viewer)
- [ ] Markdown rendering (swift-markdown + WKWebView for KaTeX/Mermaid)
- [ ] Editor with live preview
- [ ] iCloud sync (primary)
- [ ] Local SQLite metadata + FTS5

### Phase 3 — Vector Search
- [ ] On-device embedding (Apple NLEmbedding as default)
- [ ] sqlite-vec integration
- [ ] Downloadable model tiers (MiniLM → e5-small → BGE-M3)
- [ ] Settings UI for model selection
- [ ] Hybrid search (FTS5 + vector RRF)

### Phase 4 — Publishing
- [ ] Static site generator in MahoNotesKit
- [ ] GitHub OAuth + repo selection in app
- [ ] Generate HTML with syntax highlighting, KaTeX, furigana
- [ ] Push to user's GitHub repo → GitHub Pages
- [ ] CLI: `mn publish`

### Phase 5 — Polish + App Store
- [ ] Furigana rendering (native + web)
- [ ] Mermaid diagrams
- [ ] RSS feed + Open Graph
- [ ] Share extension (iOS)
- [ ] Export (PDF, EPUB)
- [ ] App Store submission

## Tech Stack Summary

| Component | Technology |
|-----------|-----------|
| CLI | Swift (shares MahoNotesKit) |
| Native App | SwiftUI universal app (macOS + iPadOS + iOS, one project) |
| Shared Logic | MahoNotesKit (Swift Package) — markdown, search, sync, CRUD |
| Published Sites | Static HTML generated by app, hosted on user's GitHub Pages |
| Markdown | remark/rehype (web), swift-markdown (native) |
| Syntax Highlighting | Shiki (web), TreeSitter (native) |
| Math | KaTeX (web), WKWebView + KaTeX (native) |
| Furigana | `{漢字|かんじ}` → `<ruby>` (web) / AttributedString (native) |
| Database | SQLite + FTS5 + sqlite-vec |
| Embeddings | Tiered: Apple NLEmbedding (built-in) / MiniLM (90MB) / e5-small (470MB) / BGE-M3 (2.2GB) |
| Sync | iCloud (app default) + GitHub (CLI/power user/publishing) |
| Git | SwiftGit2 (CLI) / GitHub REST API (iOS + macOS app, for publishing) |
| Auth | GitHub OAuth via `ASWebAuthenticationSession` (iOS/macOS) / `gh auth` (CLI) |
| Hosting | GitHub Pages (user-owned, for published notes) |
| Domain | notes.pcca.dev |

## Design Decisions

1. **CLI language**: **Swift** — shared codebase with native apps via MahoNotesKit Swift Package
2. **Native app**: **Universal app** (one Xcode project, macOS + iPadOS + iOS, shared SwiftUI code)
3. **Sync**: **iCloud** (default for app) + **GitHub** (optional, for CLI/power users/publishing)
4. **Git on iOS**: Not needed — iCloud for sync, GitHub REST API for publishing
5. **Publishing**: Static site generated by app, deployed to user's GitHub Pages (no centralized web app)
6. **Vector search**: 100% on-device, user-selectable model per device (Apple NLEmbedding → BGE-M3), sqlite-vec for local queries
7. **Furigana syntax**: `{漢字|かんじ}` → renders to HTML `<ruby>` (web) / `AttributedString` ruby annotation (native)
8. **Embedding model**: User-selectable per device; 4 tiers from Apple NLEmbedding (0MB) to BGE-M3 (2.2GB); all support 中英日
9. **Domain**: `notes.pcca.dev`
10. **App Store**: App must work standalone without server dependency
11. **Publishing**: User-owned — each user publishes to their own GitHub Pages, we don't host content

---

*Design by 真帆 🔭 — 2026-03-03*
