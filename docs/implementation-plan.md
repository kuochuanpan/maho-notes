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

### 3.1 — Static Site Generator ✅ (2026-03-05)
- [x] `SiteGenerator.swift` in MahoNotesKit (SiteConfig, GenerationResult, generate(to:notes:))
- [x] `MarkdownHTMLRenderer.swift`: swift-markdown visitor → HTML
  - Headings, bold, italic, code, links, images, tables, task lists, blockquotes, strikethrough
  - Ruby annotation: `{base|annotation}` → `<ruby>` HTML
  - Admonitions: `[!tip]`/`[!warning]`/`[!note]`/`[!info]` → styled divs
  - Math: `$...$` → `<span class="math-inline">`, `$$...$$` → `<div class="math-block">` (KaTeX CDN)
  - Mermaid: code blocks → `<div class="mermaid">` (Mermaid CDN)
  - Code blocks: `<pre><code class="language-xxx">` (highlight.js CDN)
- [x] Routes: `/index.html`, `/c/<collection>/index.html`, `/c/<collection>/<slug>.html`, `/feed.xml`
- [x] Inline CSS: light/dark mode, responsive, system font stack, admonition styling
- [x] Open Graph meta tags, reading time (word count / 200 wpm)
- [x] RSS 2.0 feed (last 20 notes)
- [x] Copies `_assets/` directory
- [x] 23 new tests (SiteGeneratorTests), 210 total

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
> UI design: **A (vault rail) + B (tree navigator) + C (content)** — see [app.md](app.md) for full spec.

### 4a — Xcode Project + iCloud Container + Vault Registry Sync

> Foundation: the app can launch, read vaults, and sync registry across devices.

- [ ] Create Xcode project (Universal App: macOS + iOS + iPadOS targets)
- [ ] Add MahoNotesKit as local SPM dependency
- [ ] App target: `Maho Notes.app`
- [ ] Bundle identifier: `com.pcca.mahonotes`
- [ ] Entitlements: iCloud Documents (`iCloud~com.pcca.mahonotes`), App Sandbox
- [ ] iCloud container: `iCloud~com.pcca.mahonotes`
  - Vault registry in container: `config/vaults.yaml`
  - iCloud vaults stored in container: `vaults/<name>/`
- [ ] `NSFileCoordinator` for safe reads/writes of vault registry + vault files
- [ ] `AppState` (`@Observable`): loads vault registry on launch, resolves vault paths per-platform
- [ ] Basic `@main` App struct with `WindowGroup` + empty `NavigationSplitView` shell
- [ ] Error state: if iCloud unavailable, show setup guidance (local-only mode works)
- [ ] CLI compatibility: macOS CLI reads the same iCloud container path
- [ ] Tests: vault registry load/save via iCloud container mock

### 4b — Core UI: Layout, Navigation, Tree Explorer

> The app can browse vaults, collections, and notes. Adaptive layout across all three platforms.
> Three-zone layout: **A (vault rail) + B (tree navigator) + C (content)** — no separate note list column.

#### A — Vault Rail (~48pt wide, Slack-inspired)
- [ ] Narrow vertical strip with rounded-square vault icons (first char + color background)
- [ ] `＋` button (top): opens "Add Vault" flow (iCloud / GitHub / Local)
- [ ] Vault grouping: iCloud → GitHub (owned) → Read-only, separated by subtle dividers
- [ ] Active vault: highlighted with left accent bar
- [ ] Read-only vaults: small 🔒 badge overlay on icon corner
- [ ] Scrollable when many vaults; author stays pinned at bottom
- [ ] Author + Settings (bottom, pinned): current vault's author initials + color; click → popover menu (Vault Settings, Search Settings, Appearance, About)
- [ ] Author icon changes when switching vaults (each vault has its own author from `maho.yaml`)

#### B — Tree Navigator (~240pt, resizable, collapsible)
- [ ] B header: current vault icon + name (changes on vault switch); read-only vaults show 🔒
- [ ] Width: default ~240pt, user-draggable (min 180pt, max 400pt), persisted per-window
- [ ] **Starred collections** section: user manually stars collections for quick access at top
- [ ] **Collections tree**: `DisclosureGroup` with unlimited nesting — collections expand in-place to show sub-collections and **notes as tree leaves** (no separate note list column)
- [ ] **Pinned notes** section: user-pinned notes (cross-collection quick access)
- [ ] **Recent** section: automatically populated, 5–10 most recently edited notes
- [ ] Sections separated by subtle dividers with small uppercase labels
- [ ] SF Symbol icons for collections (from `maho.yaml`)
- [ ] Entire B column scrolls freely

#### C — Content (remaining space)
- [ ] C header: `◀ ▶` note history navigation + breadcrumb (clickable path segments) + `＋` new note button (⌘N)
- [ ] **Smart tab bar**: hidden by default (clean); appears only when editing note A and opening another note B (preserves unsaved state); tab indicators: ✏️ editing, ● unsaved; closes when ≤ 1 tab; no hard limit
- [ ] **Floating toolbar** (bottom-right):
  - View mode: single icon cycles 👁 Preview → ✏️ Editor → ⊞ Split
  - Edit mode: expanded formatting tools (B, I, H, 🔗, 🖼, ```, 📊, {|}, mode toggle)
  - Read-only vault: 👁 dimmed/disabled, formatting toolbar never appears

#### Collapsible Panels
- [ ] ⌘⇧B: toggle B (navigator)
- [ ] ⌘⇧A: toggle A (vault rail) — also collapses B
- [ ] ⌘\\: toggle focus mode (collapse A+B together)
- [ ] Sidebar toggle button in B header (click: toggle B / long-press: toggle A+B)
- [ ] Thin edge handle (~4pt) when collapsed: click/tap to restore
- [ ] Auto-collapse: window width < 900pt → B collapses; < 600pt → A+B collapse
- [ ] Collapse state persisted per-window across app restarts

#### Title Bar — Search
- [ ] Search bar embedded in macOS title bar (like Slack)
- [ ] ⌘K opens search panel (primary trigger); ⌘⇧F as alias from editor context
- [ ] Search panel: scope picker (All Vaults / This Vault), mode picker (Text / Semantic / Hybrid)
- [ ] Type-as-you-search (debounced), results appear instantly
- [ ] Empty state: recent searches + quick access (recently opened notes)

#### Platform Adaptation
- [ ] macOS: A+B+C all visible (collapsible)
- [ ] iPad landscape: same as macOS (A+B+C)
- [ ] iPad portrait: A hidden (vault dropdown in B header), B as overlay sidebar (swipe from left), C full width
- [ ] iPhone: A hidden (vault dropdown in B header), B full-screen push, C full-screen push; no split view
- [ ] iPad: Stage Manager multi-window support

- [ ] Tests: navigation state, vault/collection filtering, collapse state persistence, platform adaptation

### 4c — Markdown Rendering + Editor

> The heaviest sub-phase. The app can display beautifully rendered markdown and edit notes.

#### Rendering (swift-markdown → AttributedString)
- [ ] CommonMark + GFM: headings, bold, italic, code, links, blockquotes, tables, task lists, strikethrough
- [ ] Code blocks with TreeSitter syntax highlighting → colored `AttributedString`
- [ ] Ruby annotation: `{base|annotation}` → custom `AttributedString` attribute → SwiftUI `rubyAnnotation` view
- [ ] Images: local (`_assets/` relative path) or remote URL → `AsyncImage`
- [ ] Math (KaTeX): `WKWebView` inline (inline `$...$` and block `$$...$$`)
- [ ] Mermaid diagrams: `WKWebView` inline
- [ ] Admonitions / callouts: styled blocks (colored border + icon: tip 💡, warning ⚠️, note 📝, info ℹ️)
- [ ] Table of contents: auto-generated from headings, shown in sidebar or note header
- [ ] Footnotes: superscript link → footnote section at bottom

#### Editor
- [ ] `TextEditor` with monospace font and markdown syntax highlighting
- [ ] Three view modes (floating toolbar toggle + ⌘E):
  - Preview (default) — rendered view, read-only
  - Editor — raw markdown with syntax highlighting
  - Split — editor left, live preview right (macOS/iPad landscape); toggle on iPhone
- [ ] Formatting toolbar: bold (**B**), italic (*I*), heading (H), link (🔗), image (🖼), code (```), table (📊), ruby `{|}`
- [ ] Auto-save: debounced (2s after last keystroke), writes via MahoNotesKit
- [ ] Frontmatter: shown as collapsible header (not raw YAML by default)
- [ ] Keyboard shortcuts: ⌘B bold, ⌘I italic, ⌘K link, ⌘N new note, ⌘S force save, ⌘E toggle edit mode, ⌘F in-note search

- [ ] Tests: markdown rendering correctness (each feature), view mode switching, auto-save

### 4d — Search UI + Settings

> In-app search (FTS5 + semantic + hybrid) and app configuration screens.

#### Search Results
- [ ] Results appear in ⌘K dropdown panel as you type
- [ ] Each result: vault badge + collection path + title + snippet (best-matching chunk for semantic)
- [ ] Source indicators for hybrid: `[text]`, `[semantic]`, `[text+semantic]`
- [ ] Click result → navigate to note with search term highlighted in C panel
- [ ] Results grouped by vault when in "All Vaults" scope

#### In-Note Search (⌘F)
- [ ] Find bar at top of note content (Preview or Editor mode)
- [ ] Highlight matches, prev/next navigation
- [ ] Replace (Editor mode only)

#### Semantic Search Requirements
- [ ] Semantic / Hybrid modes only enabled when vector index exists
- [ ] If no index: show "Build search index" button → runs `VectorIndex.buildIndex()` in background
- [ ] Model download prompt if no embedding model cached

#### Settings (standard Settings view)
- [ ] **Vaults**: list of registered vaults, add (iCloud/GitHub/Local), remove (with confirmation + `--delete` option), set primary, per-vault info (type, access, repo, last sync, note count)
- [ ] **Sync**: GitHub auth status, sign in via `ASWebAuthenticationSession` → OAuth → Keychain, auto-sync toggle, manual "Sync Now" button, sync log / last sync per vault
- [ ] **Search & Embedding**: current model info (name, size, dim, downloaded), model picker (MiniLM/E5-Small/E5-Large), download button with `ProgressView`, "Rebuild Index" button, index status
- [ ] **Appearance**: theme (System/Light/Dark), font size (slider or presets), editor font
- [ ] **About**: version, build, links (GitHub repo, docs, feedback)

- [ ] Tests: search result display, settings persistence, model download flow

### 4e — iCloud Sync: File Coordination + Conflict Resolution

> Full iCloud Documents sync for vault content. Real-time cross-device sync with conflict handling.

#### iCloud File Monitoring
- [ ] `NSMetadataQuery` with `NSMetadataQueryUbiquitousDocumentsScope` monitoring all vault dirs
- [ ] File change handling: new note → add to list + queue FTS indexing; modified → reload + update FTS + mark for re-embedding; deleted → remove from list + indexes; conflict → create .conflict file + show ⚠️ badge
- [ ] Download-on-demand: lazy files show placeholder → download triggered on access
- [ ] Download progress shown for large files (e.g., `_assets/`)
- [ ] UI updates reactive via `@Observable`

#### Conflict Resolution UI
- [ ] ⚠️ badge on conflicted notes in B panel tree + note content
- [ ] Banner: "This note has a conflict" at top of note content
- [ ] Resolve view: side-by-side diff (remote left, local right)
- [ ] Actions: "Keep Remote", "Keep Local", "Keep Both" (rename local)
- [ ] Resolution deletes the `.conflict-*` file

#### GitHub Sync from App (REST API, no git CLI)
- [ ] Clone: GitHub API get tree → download files
- [ ] Pull: compare HEAD → download changed files
- [ ] Push: create blobs → create tree → create commit → update ref
- [ ] Auth: `ASWebAuthenticationSession` → OAuth token → Keychain
- [ ] Sync ordering: iCloud settles first → GitHub sync against settled state (debounced 30s)
- [ ] Auto-sync: push on note save (debounced 30s), pull on launch + every 5 min + pull-to-refresh
- [ ] Conflict on pull: same resolution as iCloud (split into two versions)

- [ ] Tests: conflict detection, resolution flow, sync ordering, GitHub REST API mocks

### 4f — Platform Polish + iOS Extras

> From "it works" to "it's good." Platform-specific features and final polish.

#### Share Extension (iOS / iPadOS)
- [ ] Separate target: `Maho Notes Share Extension`
- [ ] Accepts: text, URLs, images, PDFs
- [ ] UI: vault picker + collection picker + title field + preview
- [ ] Creates new note via MahoNotesKit (shared App Group container)
- [ ] Text → markdown body; URL → link with title; Image → saved to `_assets/`

#### On-Demand Resources (ODR) — Embedding Models
- [ ] App Store binary ships with NO embedding models (keep under 200MB)
- [ ] Models tagged as ODR: `model-minilm` (~90MB), `model-e5small` (~470MB), `model-e5large` (~2.2GB)
- [ ] Download triggered from Settings → Search → Embedding Model
- [ ] `ProgressView` shows download progress
- [ ] Fallback: if ODR unavailable (TestFlight, sideloaded), download from HuggingFace Hub directly

#### Keychain (iOS / iPadOS / macOS)
- [ ] GitHub OAuth token in Keychain (not UserDefaults)
- [ ] Shared Keychain access group for Share Extension
- [ ] macOS app also uses Keychain (consistent; CLI uses `~/.maho/config.yaml`)

#### Platform-Specific Polish
- [ ] iOS: pull-to-refresh triggers GitHub sync
- [ ] iPad: keyboard shortcuts (same as macOS with external keyboard)
- [ ] iPad: Stage Manager multi-window support
- [ ] macOS + iPad: drag & drop (notes between collections; drop files to attach)
- [ ] macOS: menu bar quick note creation (optional)

#### Universal Polish
- [ ] Accessibility: VoiceOver labels, Dynamic Type, reduce motion
- [ ] App icon + launch screen (SF Symbol placeholder during dev)
- [ ] First-launch onboarding: sign in to iCloud, create/import vault, optional GitHub auth
- [ ] Offline mode: graceful degradation — hide sync UI, show "offline" indicator, all local ops work
- [ ] Error handling: user-friendly messages (not raw Swift errors), retry buttons for network failures

**Estimated effort:** 15–20 sessions total  
**Dependencies:** Phase 0, Phase 1 (multi-vault), Phase 2 (vector search for semantic toggle)  
**Tests:** UI tests + unit tests via MahoNotesKit  

**Sub-phase estimates:**
| Sub-phase | Effort | Notes |
|-----------|--------|-------|
| 4a | 1–2 sessions | Xcode setup + iCloud container |
| 4b | 2–3 sessions | Vault rail, tree navigator, collapsible panels, platform adaptation |
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
