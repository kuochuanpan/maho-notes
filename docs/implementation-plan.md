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

## Phase 4: Native App (Universal — macOS + iPadOS + iOS)

> One Xcode project, one SwiftUI codebase, three platforms. Share MahoNotesKit with CLI.
> iCloud is infrastructure (not an add-on) — the app needs it from day one for vault registry.

### 4a — Xcode Project + iCloud Container + Vault Registry Sync

> Foundation: the app can launch, read vaults, and sync registry across devices.

- [ ] Create Xcode project (Universal App: macOS + iOS + iPadOS targets)
- [ ] Add MahoNotesKit as local SPM dependency
- [ ] App target: `Maho Notes.app`
- [ ] Bundle identifier: `com.pcca.mahonotes`
- [ ] Entitlements: iCloud (CloudKit / iCloud Documents), App Sandbox
- [ ] iCloud container: `iCloud~com.pcca.mahonotes`
  - Vault registry in container: `config/vaults.yaml`
  - iCloud vaults stored in container: `vaults/<name>/`
- [ ] `NSFileCoordinator` for safe reads/writes of vault registry
- [ ] App reads vault registry on launch → resolves vault paths (iCloud / local / GitHub)
- [ ] Basic `@main` App struct with empty NavigationSplitView shell
- [ ] Tests: vault registry load/save via iCloud container mock

### 4b — Core UI: Sidebar, Navigation, Note List

> The app can browse vaults, collections, and notes. Adaptive layout across platforms.

- [ ] Three-column `NavigationSplitView` (adaptive: 3-col macOS/iPad landscape, 2-col iPad portrait, push iPhone)
  - Column 1: Vault picker + collection tree
  - Column 2: Note list (filtered by collection)
  - Column 3: Note content (preview placeholder initially)
- [ ] Vault picker: list all vaults from registry, "All Vaults" option
- [ ] Collection tree: nested directories as expandable `DisclosureGroup`
- [ ] Read-only badge (🔒) on read-only vaults
- [ ] Note list: sort by updated / title / custom order
- [ ] iPhone: single-column push navigation, vault picker as section headers
- [ ] iPad: two/three-column split view, Stage Manager multi-window support
- [ ] Tests: navigation state, vault/collection filtering

### 4c — Markdown Rendering + Editor

> The heaviest sub-phase. The app can display and edit notes with full markdown support.

#### Rendering
- [ ] `swift-markdown` parser → custom `AttributedString` renderer
- [ ] Heading styles, bold, italic, code, links, blockquotes
- [ ] Code blocks with TreeSitter syntax highlighting
- [ ] Ruby annotation: `{base|annotation}` → custom AttributedString attribute → custom SwiftUI view
- [ ] Images: load from relative path (`_assets/`) or remote URL
- [ ] Math: `WKWebView` + KaTeX (inline `$...$` and block `$$...$$`)
- [ ] Mermaid diagrams: `WKWebView`
- [ ] Admonitions / callouts: styled blocks (tip, warning, note, info)
- [ ] Table of contents: auto-generated from headings
- [ ] Footnotes, GFM tables, task lists, strikethrough

#### Editor
- [ ] Raw markdown text editor with syntax highlighting
- [ ] Three view modes (toolbar toggle + keyboard shortcut):
  - Preview only (default) — rendered view
  - Editor only — raw markdown
  - Split view — editor left, preview right (macOS/iPad); toggle on iPhone
- [ ] Toolbar shortcuts: bold, italic, heading, link, image, code block, table, ruby annotation
- [ ] Auto-save on pause (debounced)
- [ ] Keyboard shortcuts: ⌘N (new), ⌘S (save), ⌘F (search), ⌘⇧F (global search), ⌘E (toggle edit mode)
- [ ] Tests: markdown rendering correctness, view mode switching

### 4d — Search UI + Settings

> In-app search (FTS5 + semantic) and app configuration.

#### Search
- [ ] Global search bar (⌘⇧F): FTS5 search across all vaults
- [ ] In-note search (⌘F)
- [ ] Semantic / hybrid search toggle (when vector index available)
- [ ] Search results: vault name + collection + title + snippet
- [ ] Cross-vault search by default

#### Settings
- [ ] Vault management: add / remove / reorder vaults, set primary
- [ ] GitHub auth: `ASWebAuthenticationSession`
- [ ] Embedding model: picker with download status + progress (`ProgressView`)
- [ ] Publishing configuration
- [ ] Appearance: theme, font size
- [ ] Tests: search result display, settings persistence

### 4e — iCloud Sync: File Coordination + Conflict Resolution

> Full iCloud Documents sync for vault content (not just registry). Cross-device real-time sync.

- [ ] `NSMetadataQuery` to monitor iCloud changes (new / modified / deleted files)
- [ ] Detect download status → trigger on-demand download for lazy iCloud files
- [ ] UI updates on file change detection (reactive via Combine / `@Observable`)
- [ ] Conflict detection via `NSFileVersion`
- [ ] Conflict handling:
  - Keep remote version as `note.md`, save local as `note.conflict-{timestamp}-local.md`
  - ⚠️ badge on conflicted notes in sidebar
  - Conflict resolution UI: side-by-side compare, keep one, manual merge
  - Resolving deletes the `.conflict-*` file
- [ ] GitHub sync from app (no git CLI on iOS):
  - GitHub REST API integration
  - Auto push: debounced (30s after last edit)
  - Auto pull: on app launch + periodic (5 min) + pull-to-refresh
  - iCloud settles first → then GitHub sync
- [ ] Tests: conflict detection, resolution flow, sync ordering

### 4f — Platform Polish + iOS Extras

> From "it works" to "it's good." Platform-specific features and final polish.

#### iOS / iPadOS
- [ ] Share Extension: create new note from other apps (Safari, PDF reader, etc.)
- [ ] Pull-to-refresh: trigger sync gesture
- [ ] Keychain: auth token storage (iOS has no `~/.maho/config.yaml`)
- [ ] `UserDefaults` for preferences (instead of file-based config on iOS)
- [ ] On-Demand Resources (ODR): embedding models via Apple CDN (App Store binary size limits)

#### macOS
- [ ] Menu bar integration (if needed)
- [ ] Drag & drop refinements (macOS vs iPadOS behavior differences)

#### Universal
- [ ] Accessibility: VoiceOver, Dynamic Type
- [ ] App icon + launch screen
- [ ] First launch onboarding
- [ ] Offline mode: graceful fallback when iCloud / GitHub unavailable
- [ ] iPad: keyboard shortcuts (same as macOS with external keyboard)
- [ ] iPad: drag & drop support

**Estimated effort:** 15–20 sessions total  
**Dependencies:** Phase 0, Phase 1 (multi-vault), Phase 2 (vector search for semantic toggle)  
**Tests:** UI tests + unit tests via MahoNotesKit  

**Sub-phase estimates:**
| Sub-phase | Effort | Notes |
|-----------|--------|-------|
| 4a | 1–2 sessions | Xcode setup + iCloud container |
| 4b | 2–3 sessions | Core navigation, adaptive layout |
| 4c | 4–6 sessions | Largest: rendering + editor |
| 4d | 2–3 sessions | Search UI + settings |
| 4e | 3–4 sessions | iCloud sync + conflict resolution |
| 4f | 2–3 sessions | Polish, share extension, ODR |

---

## Phase Summary

| Phase | Description | Effort | Dependencies |
|-------|-------------|--------|--------------|
| **0** | Code ↔ Design alignment | ✅ done (1 session) | None |
| **1** | Multi-Vault | ✅ done (1 session) | Phase 0 |
| **2** | Vector Search | ✅ done (1 session) | Phase 0, CJKSQLite compat |
| **2b-CLI** | Model management + `mn model` | ✅ done (1 session) | Phase 2 |
| **3** | Publishing | 4–5 sessions | Phase 0, 1 |
| **4** | Native App (Universal) | 15–20 sessions | Phase 0, 1, 2 |

**Total estimated: ~22–28 sessions remaining (Phase 3 + 4)**

### Parallelizable Work
- Phase 3 (Publishing) can run in parallel with Phase 4a–4c — no dependency between them
- Phase 4 sub-phases must be done in order (each builds on the previous)

### Heartbeat-Friendly Tasks
Each sub-item (e.g., 0.1, 4b, 2.3) is scoped to be completable in a single session. Sub-items within a phase should be done in order (they build on each other). Phases can overlap where dependency arrows allow.

---

*Plan by 真帆 🔭 — 2026-03-05*
