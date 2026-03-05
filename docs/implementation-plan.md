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

### 0.2 — `mn init` Wizard ✅ (2026-03-04)
- [x] Interactive wizard mode: prompts for author, GitHub repo, tutorial (readLine)
- [x] Non-interactive flags: `--author <name>`, `--github <repo>`, `--non-interactive`
- [x] `--no-tutorial` flag: skip tutorial notes + collection
- [x] Global `~/.maho/` setup: creates `~/.maho/config.yaml` skeleton
- [x] Idempotent: safe to run again (never overwrites)
- [x] Core logic extracted to `MahoNotesKit/VaultInit.swift` (testable)
- [x] 10 new tests (94 total, all passing)

### 0.3 — Tutorial as Separate Vault ✅ (2026-03-05)
- [x] Created `kuochuanpan/maho-getting-started` repo with 7 tutorial notes + maho.yaml
- [x] `mn init`: clones tutorial via `git clone --depth 1` instead of inline
- [x] Offline graceful: prints warning + continues if clone fails
- [x] Removed ~130 lines of inline tutorial content from VaultInit.swift
- [x] tutorialRepoURL parameter for testability

### 0.4 — `--json` Output ✅ (2026-03-05)
- [x] Already wired: list, search, show, meta, new, collections, stats
- [x] Added: config show --json, index --json, sync --json
- [x] printJSONError helper for consistent error JSON
- [x] 6 new JSON output tests (100 total, all passing)

**Phase 0 complete! 🎉** 94 → 100 tests, 4 sub-phases done.

---

## Phase 1: Multi-Vault

> Core infrastructure for multiple vaults. Prerequisite for cross-vault search, publishing, and the native app.

### 1.1 — Vault Registry ✅ (2026-03-05)
- [x] VaultRegistry.swift: load/save `vaults.yaml` with iCloud primary + fallback + cache
- [x] Data model: VaultEntry/VaultRegistry (Codable + Sendable)
- [x] Path resolution for icloud/github/local types
- [x] CRUD helpers: findVault, addVault, removeVault, setPrimary
- [x] 17 tests

### 1.2 — `mn vault` Commands ✅ (2026-03-05)
- [x] VaultCommand with 7 subcommands: list, add (--icloud/--github/--path), remove (--delete), set-primary, info
- [x] GitHub API auto-detect (push access), import mode (auto-generate maho.yaml)
- [x] Override flags: --readonly, --readwrite, --import
- [x] Registered in MahoNotes.swift
- [x] 10 tests

### 1.3 — Cross-Vault Wiring ✅ (2026-03-05)
- [x] VaultOption.swift: resolve `--vault <name>` via registry, `$MN_VAULT`, primary fallback, legacy auto-detect
- [x] `--all` flag on list/search/index/sync (search defaults to cross-vault)
- [x] Read-only enforcement: validateWritable() on new/delete/meta --set
- [x] 10 CrossVaultTests (registry resolution, multi-vault notes/search, read-only flags)

**Phase 1 complete! 🎉** 100 → 139 tests, 3 sub-phases done.

**Estimated effort:** 3–4 sessions (actual: 1 session)  
**Dependencies:** Phase 0 (collections in maho.yaml)  
**Tests:** ~30 new tests expected

---

## Phase 2: Vector Search

> On-device semantic search with multilingual embedding models.
> Runtime: `swift-embeddings` (MLTensor) + `SQLiteVec` (sqlite-vec). No Apple NLEmbedding — see Decision #21.

### 2.1 — sqlite-vec + CJKSQLite Compatibility Spike ✅ (2026-03-05)
- [x] Vendored sqlite-vec v0.1.6 into swift-cjk-sqlite v0.2.0 (symbol conflict solved)
- [x] FTS5 + CJK + vec0 coexist in same index.db ✅
- [x] `VectorIndex.swift` in MahoNotesKit: vec0 virtual table + chunks metadata table
- [x] Schema: `vec_chunks` (vec0) + `chunks` (path, chunk_id, chunk_text, model, mtime)
- [x] 8 tests (insert, query, incremental, model mismatch detection)
- [x] 176 tests total, all passing

### 2.2 — Embedding Pipeline ✅ (2026-03-05)
- [x] Added `swift-embeddings` 0.0.26 SPM dependency; macOS 15+ minimum
- [x] `EmbeddingProvider.swift` protocol (Sendable, async embed/embedBatch/dimensions/modelIdentifier)
- [x] `SwiftEmbeddingsProvider.swift`: wraps Bert (MiniLM) + XLMRoberta (e5-small), auto-download from HuggingFace Hub
- [x] `EmbeddingModel` enum: `.minilm` (all-MiniLM-L6-v2, 384d, ~90MB) + `.e5Small` (multilingual-e5-small, 384d, ~470MB)
- [x] `Chunker.swift`: heading-based split, frontmatter stripping, title prefix, short-note single chunk
- [x] `mn index --model <name>`: builds vector index with specified model
- [x] VectorIndex.swift updated: uses Chunker + async buildIndex with embedder closure
- [x] Incremental: mtime-based skip, model mismatch detection, prune deleted notes
- [x] 5 new tests (Chunker: short/long/frontmatter/empty, EmbeddingProvider: mock)

### 2.3 — Semantic Search ✅ (2026-03-05)
- [x] `mn search --semantic "query"`: embed query → sqlite-vec cosine → chunk-to-note aggregation
- [x] `--limit N` flag (default: 10)
- [x] Cross-vault semantic search (`--all`)
- [x] Result format: path, score, snippet from best-matching chunk
- [x] SearchCommand now AsyncParsableCommand (root MahoNotes too)

### 2.4 — Hybrid Search (RRF) ✅ (2026-03-05)
- [x] `HybridSearch.swift`: RRF merge (k=60, 1:1 FTS5:vector weight)
- [x] `--hybrid` flag: FTS5 + vector → RRF merge → sorted results
- [x] Source indicators: `[fts]`, `[vec]`, `[fts+vec]` in output
- [x] Default search: FTS5 only; `--semantic`: vector only; `--hybrid`: combined
- [x] 3 new tests (RRF merge correctness, limit, empty inputs)
- [x] 3 new test suites (ChunkerTests, HybridSearchTests, EmbeddingProviderTests)

**Phase 2 complete! 🎉** 165 → 176 tests, 4 sub-phases done.

**Estimated effort:** 4–5 sessions (actual: 1 session)  
**Dependencies:** Phase 0, swift-cjk-sqlite compatibility  
**Tests:** 19 new tests (8 VectorIndex + 5 Chunker + 3 Hybrid + 3 Embedding)

### Phase 2b-CLI: Model Management + BGE-M3
> CLI-side model improvements. No dependency on native app.

#### 2b.1 — Pro Model Tier ✅ (2026-03-05)
- [x] `EmbeddingModel.e5large` case (`intfloat/multilingual-e5-large`, 1024 dim, ~2.2GB)
  - Originally planned BGE-M3, but it only has pytorch_model.bin (no safetensors) → incompatible with swift-embeddings
  - E5-Large is same family as E5-Small, XLMRoberta, safetensors ✅
- [x] `dimensions` per-case: minilm=384, e5small=384, e5large=1024
- [x] `displayName` + `approximateSize` computed properties
- [x] XLMRoberta loading for E5-Large (`.init()` loadConfig, no weight prefix)
- [x] `VectorIndex`: stores dimensions in `_vec_schema` table, detects dimension mismatch → error with `mn index --full` hint
- [x] 5 new tests (EmbeddingProviderTests) + 2 new tests (VectorIndexTests dimension mismatch)

#### 2b.2 — `mn model` Subcommand ✅ (2026-03-05)
- [x] `mn model list` — table with name, display name, dimensions, size, downloaded status (✓/—)
- [x] `mn model download <name>` — pre-download model via warmup embed
- [x] `mn model remove <name>` — delete cached model directory
- [x] `--json` output support
- [x] Model cache detection: `~/Documents/huggingface/models/{org}/{model}` (+ alt `models--{org}--{model}`)
- [ ] Download progress: stderr output during download (deferred — swift-embeddings/HubApi doesn't expose progress callbacks)

**Phase 2b-CLI complete! 🎉** 176 → 187 tests, commits `902c7f4` → `918a6a0`.

#### Bugs Found During Testing
- [x] `String(format:)` + `NSString.utf8String!` → SIGSEGV in `mn model list` (replaced with Swift `.padding`)
- [x] Model cache path was `models--org--model` but HubApi uses `models/org/model` (fixed to check both)
- [x] `_vec_schema` migration: old DBs lack `dimensions` column → added `ALTER TABLE` + backfill
- [x] e5-small `loadConfig`: doesn't need `.addWeightKeyPrefix("roberta.")` (weights don't have prefix)
- [x] BGE-M3 has no safetensors → replaced with `intfloat/multilingual-e5-large` (same 1024d, safetensors ✅)
- [x] `mn index --full` blocked by dimension mismatch at init → added `skipDimensionCheck` + `resetSchema()`
- [x] `SearchCommand` failed on dimension mismatch when reading existing index → `skipDimensionCheck: true`

#### Already Done
- [x] Standard tier: multilingual-e5-small — implemented in Phase 2.2 (`EmbeddingModel.e5small`)
- [x] Model selection: `mn index --model <name>` + `mn config set embed.model <name>`
- [x] Model auto-download from HuggingFace Hub on first `mn index`

### Phase 2b-App (Deferred to Phase 4)
> Native app model management — requires SwiftUI.

- [ ] Settings UI: Search → Embedding Model picker with download status
- [ ] Visual download progress bar (ProgressView)
- [ ] On-Demand Resources (ODR) for App Store distribution (Apple-managed CDN, lazy download)

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
| **0** | Code ↔ Design alignment | ✅ done (1 session) | None |
| **1** | Multi-Vault | ✅ done (1 session) | Phase 0 |
| **2** | Vector Search | ✅ done (1 session) | Phase 0, CJKSQLite compat |
| **2b-CLI** | BGE-M3 + `mn model` | 1–2 sessions | Phase 2 |
| **2b-App** | Model management UI + ODR | deferred | Phase 4 |
| **3** | Publishing | 4–5 sessions | Phase 0, 1 |
| **4** | Native App (macOS) | 8–12 sessions | Phase 0, 1, 2 |
| **5** | iCloud Sync | 4–6 sessions | Phase 4 |
| **6** | iOS / iPadOS | 3–4 sessions | Phase 4, 5 |

**Total estimated: ~27–38 sessions**

### Parallelizable Work
- Phase 2b-CLI, Phase 3 (Publishing) can run in parallel — no dependency between them
- Phase 1 (Multi-Vault) must complete before Phase 3 and Phase 4
- Phase 0 must complete first (everything depends on correct config model)

### Heartbeat-Friendly Tasks
Each sub-item (e.g., 0.1, 1.2, 2.3) is scoped to be completable in a single session. Sub-items within a phase should be done in order (they build on each other). Phases can overlap where dependency arrows allow.

---

*Plan by 真帆 🔭 — 2026-03-04*
