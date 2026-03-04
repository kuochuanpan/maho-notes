# Maho Notes — Design Document

> A multilingual personal knowledge base with beautiful markdown rendering, cross-platform native apps, on-device vector search, and selective publishing.

## Overview

Maho Notes is a markdown-first knowledge management system with first-class support for **Chinese (中文)**, **English**, **Japanese (日本語)**, and **Korean (한국어)**. It supports multiple collections, on-device multilingual semantic search, and the ability to selectively publish notes as public web pages via GitHub Pages. Works offline, syncs via iCloud, and optionally integrates with GitHub for version control and publishing.

### Multilingual Support 🌐
- **UI**: Chinese, English, Japanese, Korean (user-selectable)
- **Content**: Full Unicode support, mixed-language notes
- **Search**: FTS5 + vector search work across all four languages (powered by [`swift-cjk-sqlite`](https://github.com/mahopan/swift-cjk-sqlite))
- **Ruby annotation**: `{base|annotation}` syntax — works for Japanese furigana (`{漢字|かんじ}`), Taiwanese Tâi-lô (`{台灣|Tâi-oân}`), Chinese Zhuyin/Pinyin (`{漢字|ㄏㄢˋ ㄗˋ}`), Korean Hanja (`{韓國|한국}`), etc.
- **Embedding models**: Multilingual semantic search across 中英日韓 (built-in tier has limited CJK quality; Light tier and above recommended)

## Architecture

```
┌───────────────────────────┐  ┌──────────┐
│   Universal App (SwiftUI)  │  │   CLI    │
│  macOS + iPadOS + iOS      │  │  (mn)    │
└──────────┬────────────────┘  └────┬─────┘
           │                        │
     ┌─────▼────────────────────────▼──────┐
     │           MahoNotesKit              │
     │  (Markdown, Search, CRUD, Sync)     │
     └──┬──────────┬──────────┬──────┬─────┘
        │          │          │      │
   ┌────▼───┐ ┌───▼────────┐ │ ┌────▼─────┐
   │ iCloud  │ │swift-cjk-  │ │ │Embeddings│
   │ (auto)  │ │sqlite      │ │ │(on-device)│
   └────┬────┘ │FTS5 + CJK  │ │ │CoreML/NL │
        │      │tokenizer   │ │ └──────────┘
        │      └──┬─────────┘ │
        │    ┌────▼────┐  ┌───▼────┐
        │    │  FTS5    │  │sqlite- │
        │    │  index   │  │vec     │
        │    └─────────┘  └────────┘
        │
   ┌────▼─────┐    ┌──────────────┐
   │  GitHub   │───→│ GitHub Pages │
   │  (opt.)   │    │ (published)  │
   └──────────┘    └──────────────┘

Sync: iCloud (automatic) ←→ Vault ←→ GitHub (explicit, mn sync)
Publishing: Vault → static HTML → user's GitHub repo → GitHub Pages
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

> Collection is inferred from the file path: `japanese/grammar/001-kunyomi-onyomi.md` → collection: `japanese`

### Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | string | ✅ | Display title |
| `tags` | string[] | ❌ | Searchable tags |
| `created` | datetime | ✅ | Creation timestamp |
| `updated` | datetime | ✅ | Last modified |
| `public` | boolean | ❌ | If true, publishable as web page (default: false) |
| `slug` | string | ❌ | URL slug for published notes |
| `author` | string | ❌ | `maho` or `kuochuan` (default from `maho.yaml`) |
| `draft` | boolean | ❌ | Draft status (default: false) |
| `order` | number | ❌ | Sort order within collection |
| `series` | string | ❌ | Group notes into a series (e.g., "日語基礎") |

> **Note:** Collection is determined by the note's directory path, not by a frontmatter field. A note at `japanese/grammar/001-xxx.md` belongs to the `japanese` collection. This avoids redundancy and prevents path/metadata inconsistency.

### Configuration

Two layers of config: **vault-level** (shared across devices) and **device-level** (local only).

```
maho-vault/
  maho.yaml              # Vault-level config (synced with vault)
  .maho/
    config.yaml           # Device-level config (gitignored)
```

#### maho.yaml (vault-level, synced)
```yaml
author:
  name: Kuo-Chuan Pan
  url: https://pcca.dev
github:
  repo: kuochuanpan/maho-vault
site:
  domain: notes.pcca.dev
  title: Kuo-Chuan's Notes
  theme: default
```

- `author`: default author info for new notes (`mn new` auto-fills frontmatter)
- `github`: vault repo for sync + publishing
- `site`: published site settings (domain, title, theme)

#### .maho/config.yaml (device-level, gitignored)
```yaml
embed:
  model: bge-m3           # per-device embedding model choice
```

- Auth tokens stored securely in `.maho/` (gitignored, never synced)
- Embedding model is per-device (iPhone → Light, Mac → Pro)

#### CLI (`mn config`)
```bash
# Phase 1a — basic config read/write
mn config                              # show all config (vault + device)
mn config --set author.name "Name"     # set vault-level config (maho.yaml)
mn config --set embed.model bge-m3     # set device-level config (.maho/config.yaml)

# Phase 1c — GitHub auth
mn config auth                         # read $GITHUB_TOKEN or `gh auth` token → store in .maho/
mn config auth --status                # check auth status
```

### Directory Structure (maho-vault)

```
maho-vault/
├── maho.yaml                  # Vault-level config (author, github, site) — synced
├── collections.yaml           # Collection definitions — synced
├── getting-started/           # Tutorial collection (auto-generated by `mn init`, safe to delete)
│   ├── _index.md              # Welcome to Maho Notes
│   ├── 001-your-first-note.md
│   ├── 002-collections.md
│   ├── 003-markdown-features.md  # Math, Mermaid, ruby annotation, callouts
│   ├── 004-search.md
│   ├── 005-sync-and-github.md
│   └── 006-publishing.md
├── japanese/                  # Collection: 日本語
│   ├── _index.md              # Collection overview (optional at any directory level)
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
├── _assets/                   # Shared images/attachments (referenced via relative paths)
│   └── ...
└── .maho/                     # Local-only metadata (gitignored, NOT synced)
    ├── config.yaml            # Device-level config (embed model, etc.)
    ├── index.db               # SQLite: metadata + FTS5 + vector embeddings
    ├── publish-manifest.json  # Content hashes for incremental publishing
    └── cache/                 # Rendered HTML cache
```

#### Why Two Config Files?
- `maho.yaml` — vault-level settings (author, GitHub, site). Rarely changes.
- `collections.yaml` — content organization. Changes often (add/rename/reorder collections).

Keeping them separate reduces merge conflict risk when syncing via GitHub.

### Nested Directories (Unlimited Depth)

Collections support **unlimited nesting**. The filesystem hierarchy IS the organization:

```
japanese/                  ← collection (top-level = defined in collections.yaml)
  grammar/                 ← subdirectory (any depth)
    basics/                ← deeper nesting is fine
      001-particles.md
    advanced/
      001-keigo.md
  vocabulary/
    001-star.md
```

- Top-level directories are collections (must be listed in `collections.yaml`)
- Subdirectories within a collection are free-form — create whatever hierarchy makes sense
- `_index.md` can appear at any level as a directory overview page
- App UI renders the tree structure; CLI uses path-based navigation

### collections.yaml

Collections are **entirely user-defined**. The app ships with no hardcoded collections — when a fresh vault is created, it includes a `getting-started` tutorial collection with a few example notes (usage, markdown features, sync & GitHub, publishing, etc.). These are real markdown files that users can edit or delete. Beyond that, users create their own collections via the app UI or by editing `collections.yaml` directly. The following is just an example:

```yaml
# Example — each user's vault has its own collections.yaml
# These are NOT built into the app; users create whatever they need.
# Icons use SF Symbols names (rendered via Image(systemName:) in SwiftUI).
# Users can pick icons from an SF Symbols picker in the app UI.
# `mn init` auto-generates a getting-started collection; users can remove it anytime.
collections:
  - id: getting-started
    name: Getting Started
    icon: questionmark.circle
    description: Tutorial — how to use Maho Notes (safe to delete)
  - id: japanese
    name: 日本語
    icon: character.book.closed
    description: 日語學習筆記
  - id: astronomy
    name: 天文筆記
    icon: sparkles
    description: 天文物理研究筆記
  - id: simulation
    name: 模擬日誌
    icon: terminal
    description: 數值模擬運行紀錄與分析
  - id: software
    name: 軟體開發
    icon: wrench.and.screwdriver
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
- **Ruby annotation** — `{base|annotation}` syntax for phonetic guides, language-agnostic:
  - Japanese furigana: `{漢字|かんじ}`
  - Taiwanese Tâi-lô/POJ: `{台灣|Tâi-oân}`
  - Chinese Zhuyin: `{漢字|ㄏㄢˋ ㄗˋ}`
  - Chinese Pinyin: `{漢字|hànzì}`
  - Korean readings: `{韓國|한국}`

### Rendering Stack
- **Native (SwiftUI)**: `swift-markdown` for parsing → custom `AttributedString` renderer, `WKWebView` fallback for complex content (KaTeX, Mermaid)
- **Static Site Generator** (for publishing): Swift-native HTML generation using templates (e.g., `Plot` or custom Swift DSL). Syntax highlighting via `Splash` (Swift) or pre-built highlight.js bundle. KaTeX/Mermaid via bundled JS in the generated HTML.
- **CLI** (macOS / Linux): terminal-friendly output (no rendering needed, just metadata + search results)

## CLI (`mn`)

The CLI is a first-class interface — not just for humans, but for AI agents.
It must support full CRUD, search, and publishing with scriptable (JSON) output.

```bash
# ── Init ──────────────────────────────────────────
mn init                               # create vault: maho.yaml + collections.yaml + getting-started/ + .maho/
mn init --vault <path>                # create at specific path
# Creates: maho.yaml, collections.yaml (with getting-started collection), getting-started/ tutorial notes, .maho/
# Idempotent: safe to run on existing vault (only adds missing files, never overwrites)
# Universal app reuses the same init logic for first-launch setup

# ── Create & Delete ───────────────────────────────
mn new "Title" --collection japanese --tags "N5,漢字"  # creates in japanese/ dir, auto-generates frontmatter
mn new "Title" --collection japanese/grammar --tags "N5"  # nested: creates in japanese/grammar/
mn delete <path>                      # move to trash / confirm

# ── Read ──────────────────────────────────────────
mn show <path>                        # display note with metadata
mn show <path> --body-only            # body content only (no frontmatter, for piping)
mn list                               # all notes, grouped by collection
mn list --collection japanese         # filter by collection
mn list --tag N5                      # filter by tag
mn list --series                      # list all series across vault
mn list --series "日語基礎"            # filter notes in that series

# ── Edit ──────────────────────────────────────────
mn open <path>                        # open in $EDITOR (human use, macOS/Linux)
# AI agents: edit markdown files directly (don't touch frontmatter block)

# ── Metadata ──────────────────────────────────────
mn meta <path>                        # show frontmatter
mn meta <path> --set public=true      # update frontmatter field
mn meta <path> --add-tag "grammar"    # add tag
mn meta <path> --remove-tag "draft"   # remove tag

# ── Search ────────────────────────────────────────
mn search "長音規則"                    # full-text search (FTS5)
mn search --semantic "how do vowels work"  # vector search
mn search --collection japanese "query"    # scoped search
mn search --semantic "query" --limit 5     # top-K results

# ── Publishing ────────────────────────────────────
mn publish                            # incremental: only regenerate + push changed notes
mn publish --force                    # full rebuild (e.g., after theme change)
mn publish <path>                     # set public:true + generate + push (one-step)
mn unpublish <path>                   # set public:false + remove from published site
mn publish --preview                  # local preview before push
# Workflow: mn meta --set public=true (mark only) → mn publish (deploy later)
# Or just: mn publish <path> (marks + deploys in one step)
# Publishing is incremental by default — uses content hashes to detect changes.

# ── Sync & Index ──────────────────────────────────
mn sync                               # git pull + push (no auto reindex)
mn sync --reindex                     # git pull + push + rebuild index
# First run: if vault is empty + github.repo configured → auto clone from repo
# New device setup: mn config auth → mn config --set github.repo <repo> → mn sync
mn index                              # rebuild SQLite FTS index (+ embeddings if model configured)
mn index --model bge-m3               # specify embedding model

# ── Config & Auth ─────────────────────────────────
mn config                             # show all config
mn config --set <key> <value>         # set config value
mn config --set author.name "Name"    # set default author for new notes
mn config --set github.repo "user/vault"  # set GitHub vault repo for sync
mn config --set site.domain "notes.example.com"  # set published site domain
mn config auth                        # GitHub OAuth flow
mn config auth --status               # check auth status

# ── Info ──────────────────────────────────────────
mn collections                        # list collections + series within each
mn stats                              # note/word count, per-collection and per-series breakdown
```

### AI Agent Workflow
**Rule: metadata via CLI, body content is free.**

| Operation | Method | Why |
|-----------|--------|-----|
| Create note | `mn new` | Auto-generates valid frontmatter (no `collection` field — inferred from path) |
| Modify metadata | `mn meta` | Validates fields, prevents accidental `public: true` |
| Delete / Publish | `mn delete` / `mn publish` | Safety confirmation |
| Read content | Direct file read or `mn show` | No risk, either is fine |
| Write / edit body | Direct file edit | Fine as long as frontmatter block (`---`) is untouched |
| Search | `mn search` | FTS5 / vector index |

```bash
# All commands support --json for scripting:
mn list --json
mn search "query" --json
```

### Global Flags
| Flag | Description |
|------|-------------|
| `--vault <path>` | Vault path (overrides auto-detection) |
| `--json` | Machine-readable JSON output (for AI agents / scripts) |
| `--quiet` | Suppress non-essential output |
| `--verbose` | Debug output |

### Vault Location (Resolution Order)
| Priority | Source | Path |
|----------|--------|------|
| 1 | `--vault <path>` flag | Explicit override |
| 2 | `$MN_VAULT` env var | User-configured |
| 3 | iCloud container | `~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/Documents/` (macOS) |
| 4 | Fallback | `~/maho-vault` (non-Apple platforms / CLI-only users) |

The CLI auto-detects the iCloud container on macOS, so it operates on the same vault as the app with zero config. Vault path is **not** managed by `mn config` (chicken-and-egg: config lives inside the vault).

## Vector Search

### Architecture
- **100% on-device** — no server dependency (App Store requirement)
- Each device has its own local embedding DB (not synced between devices)
- Markdown files sync via iCloud/GitHub; each device generates its own embeddings locally
- User can choose embedding model per device (bigger Mac → bigger model, iPhone → smaller model)

### Embedding Models (User-Selectable)

| Tier | Model | Size | Dim | Quality | Platforms |
|------|-------|------|-----|---------|-----------|
| 🟢 Built-in | Apple NLEmbedding | 0 MB | varies | Basic (⚠️ CJK quality limited) | All (iOS 17+, macOS 14+) |
| 🟡 Light | all-MiniLM-L6-v2 (multilingual) | ~90 MB | 384 | Good | All |
| 🟠 Standard | multilingual-e5-small | ~470 MB | 384 | Better | All |
| 🔴 Pro | BGE-M3 | ~2.2 GB | 1024 | Best | Mac recommended |

- **Default**: Apple NLEmbedding (zero download, works immediately; note: CJK/Korean quality is limited — for serious multilingual search, recommend Light tier or above)
- **Optional**: User downloads preferred model in Settings → Search → Embedding Model
- **Per-device choice**: iPhone can use Light, Mac can use Pro — independent
- Models distributed as CoreML packages via:
  - **On-Demand Resources (ODR)** for App Store builds (Apple-managed CDN, lazy download)
  - **Direct download** from GitHub Releases for CLI / sideloaded builds
  - App prompts user before downloading; shows model size + expected quality improvement

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
- **Full-text**: SQLite FTS5 with **`cjk` tokenizer** ([`swift-cjk-sqlite`](https://github.com/mahopan/swift-cjk-sqlite)) — Apple NLTokenizer for CJK segmentation (title + content + tags, always available, instant)
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
| **macOS** | Three-column sidebar | 3 view modes: preview / editor / split (default: preview) |
| **iPadOS** | Two/three-column split view | Same 3 view modes in landscape; Stage Manager multi-window |
| **iPhone** | Single-column push navigation | Compact UI, toggle view/edit |

### macOS
- Editor view modes (toggle via toolbar or shortcut):
  - **Preview only** — 閱讀模式，純渲染（預設）
  - **Editor only** — 純 markdown 編輯
  - **Split view** — 左 markdown / 右 live preview（side by side）
- Keyboard shortcuts: Cmd+N (new), Cmd+S (save), Cmd+F (search), Cmd+Shift+F (global search), Cmd+E (toggle edit mode)

### iPadOS
- Same 3 view modes as macOS (preview / editor / split) in landscape; push navigation in portrait on smaller iPads
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
  - Live preview (3 view modes on macOS/iPadOS, toggle on iPhone)
  - Toolbar shortcuts (bold, italic, heading, link, image, code block, table, ruby annotation)
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
- Beautiful rendering (syntax highlighting, KaTeX, Mermaid, ruby annotation)
- Responsive design
- RSS feed, Open Graph meta tags
- Custom domain support (user configures in GitHub Pages settings)
- SEO-friendly static HTML

## Sync Strategy

### Two Sync Layers
The vault lives in iCloud by default. GitHub is an optional second layer for power users.

```
iCloud sync (automatic, transparent)
├── Handled by OS — app/CLI don't intervene
├── Same Apple ID devices sync automatically
└── Default vault location is iCloud container

mn sync (GitHub, explicit)
├── Cross-Apple-ID bridging (e.g., Maho ↔ Kuo-Chuan)
├── Version control (git history)
├── Publishing source
└── Requires: mn config auth + mn config --set github.repo
```

`mn sync` syncs the iCloud vault ↔ GitHub repo. iCloud settles first (local), then GitHub sync runs against the settled local state.

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
- **Conflict resolution** (simple: split + manual resolve):
  1. Detect: on sync, compare `updated` timestamp + content hash
  2. If both sides changed same file → keep both versions:
     - `note.md` ← newer version
     - `note.conflict-{timestamp}-{source}.md` ← older version
  3. App shows ⚠️ badge on conflicted notes
  4. User opens both files → compares manually → keeps preferred version
  5. Resolving deletes the `.conflict-*` file
  - iCloud layer: hook into `NSFileVersion` to detect iCloud-level conflicts
  - GitHub layer: detect diverged commits on pull
  - **Rejected push (non-fast-forward)**: pull first → if conflict, split into two versions → then push. Never force push.
  - **iCloud ↔ GitHub ordering**: iCloud settles first (local), then GitHub sync runs against the settled local state. GitHub sync is debounced (30s) to avoid racing with iCloud.
  - **No auto-merge** — markdown content is hard to merge safely
  - **No lock mechanism** — too complex, doesn't work offline
- **What syncs**: Markdown files + `maho.yaml` + `collections.yaml` + `_assets/`
- **What doesn't sync**: `.maho/` (local DB, embeddings, cache, auth tokens)

### New Device Setup
No separate import command — `mn sync` handles first-time clone automatically:
```bash
mn config auth                                        # GitHub OAuth
mn config --set github.repo kuochuanpan/maho-vault    # set vault repo
mn sync                                               # detects empty vault → clones from repo
```
In app: Settings → Sync → Connect GitHub Repository → syncs automatically.

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
| iOS / iPadOS | `ASWebAuthenticationSession` (system browser) | GitHub REST API |
| macOS | `ASWebAuthenticationSession` | GitHub REST API or git |
| CLI | `gh auth` or token | git push |

All platforms can publish. No git CLI needed on iOS — pure HTTP API.

### What Gets Published
- Only notes with `public: true` in frontmatter
- Static HTML with beautiful rendering (syntax highlighting, KaTeX, ruby annotation)
- Auto-generated index page, collection pages, RSS feed
- User's private notes never leave their device/iCloud

### User Setup (One-Time)
1. In app: Settings → Publishing → Connect GitHub
2. Create or select a repo (app can create it for the user)
3. Enable GitHub Pages in repo settings (app guides the user)
4. Optional: configure custom domain (e.g., `notes.alice.dev`)

### Incremental Publishing
Publishing is incremental by default. A **publish manifest** (`.maho/publish-manifest.json`) tracks the content hash (SHA-256) of each published note.

On `mn publish`:
1. Scan all `public: true` notes
2. Compute content hash (frontmatter + body) for each
3. Compare with manifest:
   - **Hash changed** → regenerate HTML, include in commit
   - **Hash unchanged** → skip
   - **New `public: true`** → generate HTML
   - **In manifest but now `public: false` or deleted** → remove HTML
4. Single commit + push with all changes

Use `mn publish --force` to regenerate all HTML (e.g., after a theme change).

### CLI
```bash
mn publish                          # incremental — only changed notes
mn publish --force                  # full rebuild
mn publish japanese/grammar/001-kunyomi-onyomi.md  # publish single note
mn unpublish <path>                 # remove from published site
mn publish --preview                # local preview before pushing
```

### Static Site Features
- Clean, responsive theme (light/dark mode)
- Syntax highlighting, KaTeX math, Mermaid diagrams, ruby annotation
- Collection-based navigation
- RSS feed
- Open Graph meta tags for social sharing
- Reading time estimate
- Customizable theme (future: user-selectable themes)

### Our Instance
- `notes.pcca.dev` → Kuo-Chuan's personal published notes (our own GitHub Pages)
- Not a shared platform — just our own deployment of the same tool

## Development Phases

### Phase 1a — CLI Core ✅ complete
Local CRUD fully functional. No network, no database.
- [x] Vault directory structure + collections.yaml
- [x] CLI (`mn`): new, list, show, search (basic grep)
- [x] Initial Japanese notes populated (7 notes)
- [x] **Migration**: Remove `collection` field from existing note frontmatter (infer from path)
- [x] **Migration**: Update `collections.yaml` icons from emoji to SF Symbols
- [x] **Migration**: Update `Note` model + `Vault` — collection inferred from `relativePath`, not frontmatter
- [x] **Migration**: Remove `SyncCommand` from registered subcommands (sync is Phase 1c; keep source files for later)
- [x] **Migration**: Add `_index.md` to existing collection directories (japanese/, astronomy/, etc.)
- [x] CLI: `mn init` (create vault + `maho.yaml` + `collections.yaml` + `getting-started/` + `.maho/`)
- [x] CLI: open, delete
- [x] CLI: meta (frontmatter manipulation — key whitelist, blocked keys, public=true warning)
- [x] CLI: config (vault-level `maho.yaml` + device-level `.maho/config.yaml` — key validation)
- [x] CLI: collections, stats (including series)
- [x] CLI: `--json` output for all commands (`Note` + `Collection` conform to `Codable`)
- [x] CLI: `mn show --body-only` (pipe-friendly body output)
- [x] CLI: `mn list --list-collections`, `--list-tags`, `--list-series` (discovery flags)
- [x] Nested directory support (unlimited depth within collections)
- [x] Vault location auto-detection (iCloud container on macOS, `~/maho-vault` fallback)
- [x] Friendly error when vault not found (actionable suggestions)
- [x] Collection auto-discovery from filesystem (undeclared dirs with .md files, 📁 default icon)
- [x] CLI emoji fallback for SF Symbols icons (JSON preserves raw SF Symbol names)
- [x] Unit tests: 42 tests in 8 suites (FrontmatterParser, makeSlug, nextFileNumber, Note, Collection, Vault CRUD, Config Validation, Collection Discovery)
- [x] GitHub Actions CI (swift build + swift test on macOS 15)
- [x] OpenClaw skill (`maho-notes`) for agent guardrails

### Phase 1b — Full-Text Search ✅ complete

#### Design Decisions

**Index location**: `.maho/index.db` (gitignored, not synced via iCloud or Git — each device builds its own)

**Auto-index on search**: When `mn search` is invoked and no `index.db` exists, automatically build the index first and print a one-time notice (`Building search index...`). Users should never need to manually run `mn index` before their first search.

**Incremental indexing**: `mn index` compares each note's file mtime against the last-indexed timestamp stored in a `_meta` table. Only changed/new files are re-indexed; deleted files are pruned. `mn index --full` forces a complete rebuild. This is fast enough for Phase 1b (< 1000 notes); revisit if needed.

**FTS5 content strategy**: Copy content into the FTS5 table (not `content=` external content mode). Simpler to implement, trades ~2× storage for straightforward insert/delete. Phase 3 (vector search) can revisit if `index.db` size becomes a concern.

**Ranking weights**: Use FTS5 `bm25()` with column weights — title (10.0) > tags (5.0) > body (1.0). Results sorted by weighted BM25 score descending.

**Fallback**: If `index.db` is corrupted, missing, or schema version mismatches, fall back to the existing substring search (current `Vault.searchNotes`) and print a warning suggesting `mn index --full`. Never crash on index errors.

#### Checklist

- [x] Integrate [`swift-cjk-sqlite`](https://github.com/mahopan/swift-cjk-sqlite) as SPM dependency (v0.1.0)
  - Bundles SQLite 3.48.0 with FTS5 + custom `cjk` tokenizer (Apple NLTokenizer for CJK segmentation)
  - Already has CI (macOS + iOS Simulator) + 19 regression tests
- [x] `SearchIndex` class in MahoNotesKit (FTS5 schema, index/query/prune methods)
  - Schema: `notes_fts(path, title, tags, body)` with tokenizer `cjk`
  - `_meta` table: `(path TEXT PRIMARY KEY, mtime REAL, indexed_at REAL)`
  - `_schema` table for version tracking (current: v1)
  - LIKE fallback for NLTokenizer segmentation edge cases ([swift-cjk-sqlite#1](https://github.com/mahopan/swift-cjk-sqlite/issues/1))
- [x] SQLite FTS5 index with `cjk` tokenizer for proper 中英日韓 full-text search
- [x] `mn search` upgrade: FTS5 `bm25()` ranking with column weights (title 10 / tags 5 / body 1)
  - Auto-build index on first search if `index.db` missing
  - Graceful fallback to substring search on index errors
- [x] `mn index` (build / rebuild FTS5 index from vault content)
  - Default: incremental (mtime-based diff)
  - `--full` flag: drop and rebuild from scratch
- [x] CLI and App share the same MahoNotesKit → same `swift-cjk-sqlite` → CJK search works everywhere

#### Tests (Phase 1b) — 11 tests, all passing

- [x] Index build: create index from scratch, verify all notes indexed
- [x] Index rebuild (`--full`): drop + recreate, same results
- [x] Incremental update: modify one note, re-index, verify updated
- [x] Incremental delete: remove a note file, re-index, verify pruned from index
- [x] CJK search: query in 中文、日本語、한국어、English — all return correct results
- [x] Mixed-language note: single note with 中英日韓 content, all four languages searchable
- [x] Ranking order: title match ranks above body-only match
- [x] Empty vault: `mn index` + `mn search` on empty vault — no crash, sensible output
- [x] No match: search for nonexistent term — empty results, not an error
- [x] Fallback: corrupt/delete `index.db` — SearchIndex recovers (deletes and recreates)
- [x] Auto-index: `SearchIndex.indexExists()` detection for auto-build on first search

### Phase 1c — GitHub Sync

#### Auth (`mn config auth`)
- [ ] `mn config auth` — read `$GITHUB_TOKEN` env var → fallback `gh auth token` → store in `.maho/config.yaml`
- [ ] `mn config auth --status` — show current auth state (token source, validity)
- [ ] Token stored device-level only (`.maho/config.yaml`), never synced to GitHub
- [ ] Clear error when no token found (guides user to set `$GITHUB_TOKEN` or install `gh`)
- [ ] Handle `gh` installed but not logged in (`gh auth token` exit ≠ 0) — treat as absent, guide user
- [ ] Token validation: test stored token against GitHub API → clear error + prompt re-auth on 401/403

#### Pre-flight Guards
- [ ] `git` not installed → friendly error: "Git is required. Install Xcode Command Line Tools: `xcode-select --install`"
- [ ] Vault path is iCloud container but iCloud Drive not enabled → detect + warn (non-blocking, sync may fail silently)

#### Sync (`mn sync`)
- [ ] Re-register `SyncCommand` in `MahoNotes.swift` subcommands
- [ ] Pre-flight checks: auth configured + `github.repo` set → clear errors if missing
- [ ] Normal sync: `git pull --rebase` → `git add -A` → `git commit` → `git push`
- [ ] First-run auto clone: detect empty/non-git vault + `github.repo` configured → `git clone` into vault path
- [ ] Post-clone vault validation (3-tier):
  - ✅ `maho.yaml` exists and parses → valid vault, proceed
  - ⚠️ No `maho.yaml` but has `.md` files in subdirectories (not just root README/LICENSE) → warn + suggest `mn init` to convert
  - ❌ No `.md` content files (only README.md/LICENSE.md/etc. or non-markdown repo) → error, refuse to use as vault
  - Heuristic: scan for `.md` files excluding common root-only files (`README.md`, `LICENSE.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`)
- [ ] Existing vault, no remote: `git remote add origin` from `github.repo` config
- [ ] `mn sync --reindex` — rebuild FTS index after sync (call `SearchIndex.rebuildIndex()`)
- [ ] Auth token injection: use stored token for HTTPS remote (set `GIT_ASKPASS` or URL-embed token)

#### Conflict Handling (minimal for CLI)
- [ ] Detect rebase conflict → `git rebase --abort`
- [ ] Fallback to `git pull --no-rebase` (merge)
- [ ] If merge conflict: save local version as `<note>.conflict-<timestamp>-local.md`, accept remote
- [ ] Print clear message listing conflicted files + `.conflict-*` paths
- [ ] No diff UI in CLI — user resolves manually by comparing the two files, then deletes `.conflict-*`

#### Rejected Push (non-fast-forward)
- [ ] Detect non-fast-forward push failure → auto `git pull` → retry push
- [ ] If pull causes conflict → apply conflict handling above

#### `.gitignore`
- [ ] Ensure `mn init` writes `.gitignore` with `.maho/` entry (DB, embeddings, auth, cache)
- [ ] `mn sync` first-run: verify `.gitignore` exists, add `.maho/` if missing

#### Tests
- [ ] Auth: reads `$GITHUB_TOKEN` env var correctly
- [ ] Auth: falls back to `gh auth token` when env var absent
- [ ] Auth: `--status` shows token source and masked value
- [ ] Auth: clear error message when no token available
- [ ] Auth: `gh` installed but not logged in → treated as absent, shows guidance
- [ ] Auth: stored token invalid (401) → clear error + prompt re-auth
- [ ] Pre-flight: `git` not found → friendly install guidance
- [ ] Sync: normal pull + commit + push flow (mock git)
- [ ] Sync: first-run clone when vault is empty + repo configured
- [ ] Sync: post-clone valid vault (`maho.yaml` present) → succeeds
- [ ] Sync: post-clone markdown repo without `maho.yaml` → warning + suggest `mn init`
- [ ] Sync: post-clone code repo (no content `.md` files, only README) → error, refused
- [ ] Sync: `--reindex` triggers FTS index rebuild after sync
- [ ] Sync: error when auth not configured
- [ ] Sync: error when `github.repo` not set
- [ ] Conflict: rebase conflict → abort → merge fallback → `.conflict-*` file created
- [ ] Conflict: non-fast-forward push → auto pull → retry
- [ ] `.gitignore`: `.maho/` entry present after init and first sync

### Phase 2 — Universal App (macOS + iPadOS + iOS)
- [ ] Xcode project with macOS + iOS targets (universal app)
- [ ] SwiftUI: NavigationSplitView (auto-adapts: sidebar/split/push)
- [ ] Markdown rendering (swift-markdown + WKWebView for KaTeX/Mermaid)
- [ ] Editor with live preview (split on macOS/iPad, toggle on iPhone)
- [ ] iCloud sync (default, vault in iCloud container)
- [ ] GitHub sync (optional, for cross-Apple-ID / AI agent use)
- [ ] GitHub OAuth via `ASWebAuthenticationSession` (replaces Phase 1c token-based auth)
- [ ] Conflict UI: ⚠️ badge on conflicted notes, user opens both files to resolve, deleting `.conflict-*` clears badge
- [ ] Local SQLite metadata + FTS5
- [ ] CJK tokenizer already available via `swift-cjk-sqlite` (from Phase 1b)

### Phase 3 — Vector Search
- [ ] On-device embedding (Apple NLEmbedding as default)
- [ ] sqlite-vec integration
- [ ] Downloadable model tiers (MiniLM → e5-small → BGE-M3 via CoreML)
- [ ] Settings UI: model selection per device
- [ ] Hybrid search (FTS5 + vector RRF)
- [ ] CLI: `mn index --model <tier>`

### Phase 4 — Publishing (All Platforms)
- [ ] Static site generator in MahoNotesKit
- [ ] GitHub OAuth via `ASWebAuthenticationSession` (iOS/iPadOS/macOS)
- [ ] Generate HTML with syntax highlighting, KaTeX, ruby annotation
- [ ] Push to user's GitHub repo → GitHub Pages (REST API)
- [ ] CLI: `mn publish`, `mn publish --preview`
- [ ] Published site: index page, collection pages, RSS feed

### Phase 5 — Polish + App Store
- [ ] Multilingual UI (中文 / English / 日本語 / 한국어)
- [ ] Ruby annotation rendering (native + published sites) — furigana, Tâi-lô, Zhuyin, etc.
- [ ] Mermaid diagrams
- [ ] RSS feed + Open Graph meta tags
- [ ] Share extension (iOS/iPadOS)
- [ ] Export (PDF, EPUB)
- [ ] Customizable published site themes
- [ ] App Store submission

## Tech Stack Summary

| Component | Technology |
|-----------|-----------|
| CLI | Swift (shares MahoNotesKit) |
| Native App | SwiftUI universal app (macOS + iPadOS + iOS, one project) |
| Shared Logic | MahoNotesKit (Swift Package) — markdown, search, sync, CRUD |
| Published Sites | Static HTML generated by app, hosted on user's GitHub Pages |
| Markdown | swift-markdown (native), Swift HTML templates (static site generator) |
| Syntax Highlighting | TreeSitter (native), Splash or highlight.js (static site) |
| Math | WKWebView + KaTeX (native), KaTeX (static site) |
| Ruby Annotation | `{base|annotation}` → `<ruby>` (web) / AttributedString (native) — furigana, Tâi-lô, Zhuyin, Pinyin, etc. |
| Database | [`swift-cjk-sqlite`](https://github.com/mahopan/swift-cjk-sqlite) (SQLite 3.48 + FTS5 + CJK tokenizer) + sqlite-vec |
| Embeddings | Tiered: Apple NLEmbedding (built-in) / MiniLM (90MB) / e5-small (470MB) / BGE-M3 (2.2GB) |
| Sync | iCloud (app default) + GitHub (CLI/power user/publishing) |
| Git | Shell out to `git` (CLI) / GitHub REST API (iOS + macOS app, for sync + publishing) |
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
7. **Ruby annotation syntax**: `{base|annotation}` → renders to HTML `<ruby>` (web) / `AttributedString` (native). Language-agnostic: works for Japanese furigana, Taiwanese Tâi-lô/POJ, Chinese Zhuyin/Pinyin, Korean readings, etc.
8. **Embedding model**: User-selectable per device; 4 tiers from Apple NLEmbedding (0MB) to BGE-M3 (2.2GB); built-in has limited CJK/Korean, Light+ recommended for 中英日韓
9. **Domain**: `notes.pcca.dev`
10. **App Store**: App must work standalone without server dependency
11. **Publishing**: User-owned — each user publishes to their own GitHub Pages, we don't host content

---

*Design by 真帆 🔭 — 2026-03-04*
