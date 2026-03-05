# Implementation Plan

> Based on design docs review (2026-03-04). Docs describe **target state**; this file tracks implementation order.

## Current State (as of 2026-03-04)

### ✅ Implemented
- CLI commands: `init`, `list`, `show`, `new`, `delete`, `open`, `search` (FTS5), `meta`, `config` (show/set/auth), `collections`, `stats`, `index`, `sync`
- MahoNotesKit: Note, Vault, Collection, Config, Auth, SearchIndex (FTS5 + CJK), FrontmatterParser, GitSync
- 84 tests, CI green
- Dependencies: swift-argument-parser, Yams, swift-cjk-sqlite

### ⚠️ Code ↔ Design Drift (Must Fix First)
1. **`mn init` still creates `collections.yaml`** — design says collections live in `maho.yaml` (Decision #13)
2. **`mn init` is not a wizard** — design says interactive first-run setup (Decision #15)
3. **`mn init` creates tutorial notes inline** — design says tutorial should be a separate read-only vault cloned from `kuochuanpan/maho-getting-started`
4. **No `--json` flag** on any command — design says all commands support `--json`
5. **`--vault` flag** exists but no multi-vault resolution — currently just a path override

### ❌ Not Yet Implemented
- Multi-vault: `mn vault add/remove/list/set-primary/info`, vault registry, cross-vault search
- Vector search: sqlite-vec, embedding pipeline, `mn search --semantic`, hybrid search
- Publishing: `mn publish/unpublish`, static site generator, incremental manifest
- Native app: SwiftUI universal app (macOS + iPadOS + iOS)
- iCloud sync: iCloud container, cross-device vault sync, conflict detection

---

## Phase 0: Code ↔ Design Alignment

> Fix drift between current code and design docs. No new features — just bring code in line with what docs say.

### 0.1 — Merge `collections.yaml` into `maho.yaml` ✅ (2026-03-04)
- [x] Update `Collection.swift`: read collections from `maho.yaml` instead of separate file
- [x] Update `mn init`: write collections into `maho.yaml`, stop creating `collections.yaml`
- [x] Migration: if `collections.yaml` exists on load, merge into `maho.yaml` + delete old file + print notice
- [x] Update all tests (4 files + 1 migration test added)
- [x] 85 tests passing

### 0.2 — `mn init` Wizard
- [ ] Interactive mode (default): prompt for vault type (iCloud / Local / GitHub), author name, optional GitHub repo
- [ ] Non-interactive flags: `--icloud`, `--path <dir>`, `--author <name>`, `--github <repo>`
- [ ] `--no-tutorial` flag: skip tutorial vault clone
- [ ] Global `~/.maho/` setup: create if missing, write `config.yaml` skeleton
- [ ] Idempotent: safe to run again (only add missing config, never overwrite)
- [ ] Update tests

### 0.3 — Tutorial as Separate Vault
- [ ] Create `kuochuanpan/maho-getting-started` repo with tutorial notes (currently inline in InitCommand)
- [ ] `mn init`: clone tutorial as read-only vault instead of creating files inline
- [ ] Offline graceful: skip tutorial if no network, user can `mn vault add` later
- [ ] Remove hardcoded tutorial notes from `InitCommand.swift`

### 0.4 — `--json` Output
- [ ] Add `OutputOption` (already exists as file, wire it up) with `--json` flag
- [ ] `mn list --json`: JSON array of notes
- [ ] `mn show --json`: JSON object with frontmatter + body
- [ ] `mn search --json`: JSON array of results with scores
- [ ] `mn meta --json`: JSON frontmatter
- [ ] `mn collections --json`, `mn stats --json`, `mn vault list --json`
- [ ] All error output → JSON `{ "error": "..." }` when `--json` is active

**Estimated effort:** 2–3 sessions  
**Dependencies:** None  
**Tests:** Update existing 84 + add migration test for collections.yaml → maho.yaml

---

## Phase 1: Multi-Vault

> Core infrastructure for multiple vaults. Prerequisite for cross-vault search, publishing, and the native app.

### 1.1 — Vault Registry
- [ ] `VaultRegistry.swift` in MahoNotesKit: load/save `vaults.yaml`
- [ ] Data model: `VaultEntry { name, type (icloud|github|local), github, access (readwrite|readonly), path? }`
- [ ] Registry locations:
  - macOS: `~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/config/vaults.yaml`
  - Fallback (no iCloud): `~/.maho/vaults.yaml`
- [ ] Local cache: `~/.maho/vaults-cache.yaml` (offline copy)
- [ ] Type-based path resolution (see sync-strategy.md):
  - `icloud` → iCloud container `vaults/<name>/`
  - `github` → `~/.maho/vaults/<name>/`
  - `local` → user-specified path
- [ ] `primary` field: default vault for all commands
- [ ] Tests: load/save/resolve paths

### 1.2 — `mn vault` Commands
- [ ] `VaultCommand.swift` with subcommands:
  - `mn vault list` — show all registered vaults (name, type, access, path, sync status)
  - `mn vault add <name> --icloud` — create new iCloud vault
  - `mn vault add <name> --github <repo>` — clone GitHub vault with auto-detection:
    - Check `permissions.push` via GitHub API → set access level
    - Check for `maho.yaml` in repo → native vs import mode
  - `mn vault add <name> --path <local>` — register local directory
  - `mn vault remove <name>` — unregister (keep files)
  - `mn vault remove <name> --delete` — unregister + delete
  - `mn vault set-primary <name>` — change default vault
  - `mn vault info <name>` — vault details
- [ ] Override flags: `--readonly`, `--readwrite`, `--import`
- [ ] Auto-generate `maho.yaml` for non-Maho repos (import mode)
- [ ] Register subcommand in `MahoNotes.swift`
- [ ] Tests: add/remove/list/auto-detect

### 1.3 — Cross-Vault Wiring
- [ ] Update `VaultOption.swift`: resolve `--vault <name>` via registry (not just path)
- [ ] `$MN_VAULT` env var support
- [ ] Priority: `--vault` flag → `$MN_VAULT` → primary vault → legacy auto-detect
- [ ] `mn list --all`: list notes across all vaults
- [ ] `mn search --all` (default): search across all vaults, results prefixed with vault name
- [ ] `mn search --vault <name>`: scoped to one vault
- [ ] `mn index --all`: index all vaults
- [ ] `mn index --vault <name>`: index specific vault
- [ ] `mn sync --all`: sync all vaults
- [ ] Read-only vault enforcement: block `mn new`, `mn delete`, `mn meta --set`, `mn publish` on read-only vaults
- [ ] Tests: cross-vault resolution, read-only blocking

**Estimated effort:** 3–4 sessions  
**Dependencies:** Phase 0 (collections in maho.yaml)  
**Tests:** ~30 new tests expected

---

## Phase 2: Vector Search

> On-device semantic search with multilingual embedding models.

### 2.1 — sqlite-vec Integration
- [ ] Add sqlite-vec SPM dependency to Package.swift
- [ ] Verify sqlite-vec compiles with our swift-cjk-sqlite (both extend SQLite — check for conflicts)
- [ ] `VectorIndex.swift` in MahoNotesKit: create/query vector tables
- [ ] Schema: `embeddings(path TEXT, embedding BLOB, model TEXT, mtime REAL)`
- [ ] Tests: basic insert/query with dummy vectors

### 2.2 — Embedding Pipeline
- [ ] `EmbeddingProvider.swift` protocol: `func embed(_ text: String) -> [Float]`, `var dimensions: Int`
- [ ] Tier 1 (built-in): `NLEmbeddingProvider` — Apple NLEmbedding, 0 MB download
- [ ] Model selection: `~/.maho/config.yaml` → `embed.model` field
- [ ] `mn index --model <name>`: set + re-embed with specified model
- [ ] Chunking strategy for long notes: split by headings or paragraphs, embed each chunk
- [ ] Incremental: only re-embed changed notes (mtime check)
- [ ] Tests: NLEmbedding provider, chunking, incremental logic

### 2.3 — Semantic Search
- [ ] `mn search --semantic "query"`: embed query → cosine similarity → top-K results
- [ ] `--limit N` flag for top-K (default: 10)
- [ ] Cross-vault semantic search (query all vault indices)
- [ ] Result format: path, score, snippet
- [ ] Tests: end-to-end semantic search

### 2.4 — Hybrid Search (RRF)
- [ ] Combine FTS5 results + vector results via Reciprocal Rank Fusion
- [ ] Default search mode: FTS5 only (fast, no model needed)
- [ ] `--semantic` flag: vector only
- [ ] `--hybrid` flag: combined (requires vector index)
- [ ] Graceful fallback: if no vector index exists, silently use FTS5 only
- [ ] Tests: RRF merging logic

### 2.5 — Additional Embedding Tiers (Optional, Lower Priority)
- [ ] Tier 2 (Light): all-MiniLM-L6-v2 multilingual (90MB CoreML)
- [ ] Tier 3 (Standard): multilingual-e5-small (470MB CoreML)
- [ ] Tier 4 (Pro): BGE-M3 (2.2GB CoreML, optional MLX)
- [ ] Model download + caching logic
- [ ] CLI: `mn index --model bge-m3` triggers download if not cached

**Estimated effort:** 4–5 sessions  
**Dependencies:** Phase 0  
**Tests:** ~25 new tests expected

---

## Phase 3: Publishing

> Static site generation + GitHub Pages deployment.

### 3.1 — Static Site Generator
- [ ] `SiteGenerator.swift` in MahoNotesKit:
  - Input: list of `public: true` notes
  - Output: directory of HTML files + index + RSS
- [ ] HTML template system (Swift string templates or Plot)
- [ ] Markdown → HTML rendering:
  - swift-markdown for parsing
  - Syntax highlighting: Splash (Swift-native) + bundled highlight.js
  - Math: bundled KaTeX JS/CSS
  - Ruby annotation: `{base|annotation}` → `<ruby><rb>base</rb><rp>(</rp><rt>annotation</rt><rp>)</rp></ruby>`
  - Mermaid: bundled mermaid.js
  - Admonitions / callouts
- [ ] Routes: `/`, `/c/:collection`, `/c/:collection/:slug`, `/feed.xml`
- [ ] Theme: clean responsive HTML/CSS (light/dark mode)
- [ ] Open Graph meta tags, reading time estimate
- [ ] Tests: HTML generation for various markdown features

### 3.2 — Incremental Publishing
- [ ] `PublishManifest.swift`: track content hashes (SHA-256) per published note
- [ ] `.maho/publish-manifest.json`: load/save
- [ ] On publish: compare hashes → only regenerate changed notes
- [ ] Handle deletions (note removed or set `public: false`)
- [ ] `--force` flag: full rebuild

### 3.3 — Publish Commands
- [ ] `PublishCommand.swift`:
  - `mn publish` — incremental publish
  - `mn publish --force` — full rebuild
  - `mn publish --vault <name>` — publish specific vault
  - `mn publish <path>` — mark public + generate + push (one-step)
  - `mn publish --preview` — generate to temp dir + open in browser
- [ ] `UnpublishCommand.swift`:
  - `mn unpublish <path>` — set `public: false` + remove from site
- [ ] Git push to publishing repo (separate from vault repo)
- [ ] Block on read-only vaults
- [ ] Register in `MahoNotes.swift`
- [ ] Tests: publish flow, incremental, preview

### 3.4 — Our Instance (notes.pcca.dev)
- [ ] Set up GitHub Pages repo for `kuochuanpan/maho-vault` or separate publishing repo
- [ ] Configure custom domain `notes.pcca.dev`
- [ ] Publish existing public notes as proof of concept

**Estimated effort:** 4–5 sessions  
**Dependencies:** Phase 0, Phase 1 (multi-vault for `--vault` flag)  
**Tests:** ~20 new tests expected

---

## Phase 4: Native App — macOS

> SwiftUI universal app, starting with macOS. Share MahoNotesKit with CLI.

### 4.1 — Xcode Project Setup
- [ ] Create Xcode project (Universal App: macOS + iOS + iPadOS)
- [ ] Add MahoNotesKit as local SPM dependency
- [ ] App target: `Maho Notes.app`
- [ ] Bundle identifier: `com.pcca.mahonotes`
- [ ] iCloud container: `iCloud~com.pcca.mahonotes`
- [ ] Entitlements: iCloud, App Sandbox

### 4.2 — Sidebar & Navigation (macOS)
- [ ] Three-column NavigationSplitView:
  - Column 1: Vault picker + collection tree
  - Column 2: Note list (filtered by collection)
  - Column 3: Note content (preview / editor / split)
- [ ] Vault picker: list all vaults, "All Vaults" option
- [ ] Collection tree: nested directories rendered as expandable tree
- [ ] Read-only badge (🔒) on read-only vaults
- [ ] Note list: sort by updated, title, order

### 4.3 — Markdown Rendering
- [ ] swift-markdown parser → custom `AttributedString` renderer
- [ ] Heading styles, bold, italic, code, links
- [ ] Code blocks with TreeSitter syntax highlighting
- [ ] Ruby annotation rendering: `{base|annotation}` → custom AttributedString attribute → custom SwiftUI view
- [ ] Images: load from relative path (`_assets/`) or URL
- [ ] Math: WKWebView + KaTeX (fallback for complex rendering)
- [ ] Mermaid: WKWebView
- [ ] Admonitions / callouts: styled blocks
- [ ] Table of contents: auto-generated from headings

### 4.4 — Editor
- [ ] Raw markdown text editor with syntax highlighting
- [ ] Three view modes (toolbar toggle + keyboard shortcut):
  - Preview only (default) — rendered view
  - Editor only — raw markdown
  - Split view — editor left, preview right
- [ ] Toolbar shortcuts: bold, italic, heading, link, image, code block, table, ruby annotation
- [ ] Auto-save on pause (debounced)
- [ ] Keyboard shortcuts: Cmd+N, Cmd+S, Cmd+F, Cmd+Shift+F, Cmd+E

### 4.5 — Search (App)
- [ ] Global search bar (Cmd+Shift+F): FTS5 search across all vaults
- [ ] In-note search (Cmd+F)
- [ ] Semantic search toggle (when vector index available)
- [ ] Search results: show vault name + collection + title + snippet

### 4.6 — Settings
- [ ] Vault management: add/remove/reorder vaults, set primary
- [ ] GitHub auth: ASWebAuthenticationSession
- [ ] Embedding model selection + download
- [ ] Publishing configuration
- [ ] Appearance: theme, font size

**Estimated effort:** 8–12 sessions (largest phase)  
**Dependencies:** Phase 0, Phase 1 (multi-vault), Phase 2 (vector search for semantic toggle)  
**Tests:** UI tests + unit tests via MahoNotesKit

---

## Phase 5: iCloud Sync

> Make vaults sync across Apple devices via iCloud container.

### 5.1 — iCloud Container Setup
- [ ] Enable iCloud entitlement with `iCloud~com.pcca.mahonotes` container
- [ ] Vault registry in iCloud container: `config/vaults.yaml`
- [ ] iCloud vaults stored in container: `vaults/<name>/`
- [ ] File coordination: `NSFileCoordinator` for safe reads/writes

### 5.2 — Sync Detection
- [ ] `NSMetadataQuery` to monitor iCloud changes
- [ ] Detect new/modified/deleted files → update UI
- [ ] Download on-demand files (lazy download from iCloud)
- [ ] Conflict detection via `NSFileVersion`

### 5.3 — Conflict Handling
- [ ] On conflict: keep remote version as `note.md`, save local as `note.conflict-{timestamp}-local.md`
- [ ] ⚠️ badge on conflicted notes in sidebar
- [ ] Conflict resolution UI: side-by-side compare, keep one, merge manual
- [ ] Resolving deletes the `.conflict-*` file

### 5.4 — GitHub Sync from App
- [ ] GitHub REST API integration (no git CLI on iOS)
- [ ] Auto push: debounced (30s after last edit)
- [ ] Auto pull: on app launch + periodic (5 min) + pull-to-refresh
- [ ] iCloud settles first → then GitHub sync

**Estimated effort:** 4–6 sessions  
**Dependencies:** Phase 4 (app exists)  
**Tests:** Integration tests with mock iCloud

---

## Phase 6: iOS / iPadOS

> Platform adaptations for mobile.

### 6.1 — iPhone UI
- [ ] Single-column push navigation
- [ ] Vault picker as section headers
- [ ] Toggle view/edit mode
- [ ] Pull to sync
- [ ] Share sheet integration

### 6.2 — iPad UI
- [ ] Two/three-column split view (same 3 view modes as macOS)
- [ ] Stage Manager: multiple windows
- [ ] Keyboard shortcuts (external keyboard)
- [ ] Drag & drop support

### 6.3 — iOS-Specific Features
- [ ] ASWebAuthenticationSession for GitHub OAuth
- [ ] Keychain for auth token storage (instead of `~/.maho/config.yaml`)
- [ ] UserDefaults for preferences (instead of file-based config)
- [ ] On-Demand Resources (ODR) for embedding model distribution
- [ ] Share extension for quick note creation

**Estimated effort:** 3–4 sessions  
**Dependencies:** Phase 4 (macOS app), Phase 5 (iCloud sync)

---

## Phase Summary

| Phase | Description | Effort | Dependencies |
|-------|-------------|--------|--------------|
| **0** | Code ↔ Design alignment | 2–3 sessions | None |
| **1** | Multi-Vault | 3–4 sessions | Phase 0 |
| **2** | Vector Search | 4–5 sessions | Phase 0 |
| **3** | Publishing | 4–5 sessions | Phase 0, 1 |
| **4** | Native App (macOS) | 8–12 sessions | Phase 0, 1, 2 |
| **5** | iCloud Sync | 4–6 sessions | Phase 4 |
| **6** | iOS / iPadOS | 3–4 sessions | Phase 4, 5 |

**Total estimated: ~28–39 sessions**

### Parallelizable Work
- Phase 2 (Vector Search) and Phase 3 (Publishing) can run in parallel — no dependency between them
- Phase 1 (Multi-Vault) must complete before Phase 3 and Phase 4
- Phase 0 must complete first (everything depends on correct config model)

### Heartbeat-Friendly Tasks
Each sub-item (e.g., 0.1, 1.2, 2.3) is scoped to be completable in a single session. Sub-items within a phase should be done in order (they build on each other). Phases can overlap where dependency arrows allow.

---

*Plan by 真帆 🔭 — 2026-03-04*
