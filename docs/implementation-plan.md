# Implementation Plan

> Based on design docs review (2026-03-04). Docs describe **target state**; this file tracks implementation order.

## Current State (as of 2026-03-06)

### ✅ Implemented
- **CLI**: 17 commands incl. `vault`, `model`, `publish`, `unpublish`, `sync` — 229 tests, all pass
- **MahoNotesKit**: Note, Vault, Collection, Config, Auth, SearchIndex (FTS5 + CJK), VectorIndex, HybridSearch, EmbeddingProvider, Chunker, GitSync, SiteGenerator, PublishManifest, VaultRegistry (with CloudSyncMode + device type)
- **Native App**: 14 SwiftUI source files (3,495 lines), macOS + iOS targets
- **Dependencies**: swift-argument-parser, Yams, swift-cjk-sqlite (v0.2.0, FTS5+CJK+sqlite-vec), swift-embeddings, swift-markdown

### Phases Complete
- Phase 0: ✅ Code ↔ Design alignment (4 sub-phases)
- Phase 1: ✅ Multi-Vault (3 sub-phases)
- Phase 2: ✅ Vector Search (4 sub-phases)
- Phase 2b-CLI: ✅ Model management
- Phase 3.1–3.3: ✅ Publishing (SiteGenerator, PublishManifest, publish/unpublish commands)
- Phase 4a: ✅ Xcode project, iCloud container, Cloud Sync toggle

### 🔧 In Progress
- Phase 3.4: Our instance (notes.pcca.dev) — needs GitHub Pages + DNS setup
- Phase 4b–4f: Native app features (structural shell done, ~40–50% overall)

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

### 3.2 — Incremental Publishing ✅ (2026-03-05)
- [x] `PublishManifest.swift`: track content hashes (SHA-256) per published note
- [x] `.maho/publish-manifest.json`: load/save
- [x] On publish: compare hashes → only regenerate changed notes
- [x] Handle deletions (note removed or set `public: false`)
- [x] `--force` flag: full rebuild
- [x] `setFrontmatterPublic()` helper in MahoNotesKit (shared by CLI + tests)

### 3.3 — Publish Commands ✅ (2026-03-05)
- [x] `PublishCommand.swift`:
  - `mn publish` — incremental publish
  - `mn publish --force` — full rebuild
  - `mn publish --vault <name>` — publish specific vault
  - `mn publish <path>` — mark public + generate + push (one-step)
  - `mn publish --preview` — generate to temp dir + open in browser
- [x] `UnpublishCommand.swift`:
  - `mn unpublish <path>` — set `public: false` + remove from site
- [x] Git push to publishing repo (separate from vault repo)
- [x] Block on read-only vaults (via `validateWritable()`)
- [x] Register in `MahoNotes.swift`
- [x] Tests: 13 new PublishManifest tests (223 total)

### 3.4 — Our Instance (notes.pcca.dev) 🔧 (2026-03-05)
- [x] Set up GitHub Pages repo for `kuochuanpan/maho-vault` — workflow deployed (`e438266`)
- [x] Publish existing public notes as proof of concept — 10 notes (getting-started + astronomy), 14 pages generated
- [ ] Configure custom domain `notes.pcca.dev` — needs repo admin to enable Pages + DNS CNAME
- [ ] Repo admin: enable Pages in Settings → Pages → Source: GitHub Actions

**Estimated effort:** 4–5 sessions  
**Dependencies:** Phase 0, Phase 1 (multi-vault for `--vault` flag)  
**Tests:** ~20 new tests expected

---

## Phase 4: Native App (Universal — macOS + iPadOS + iOS)

> One Xcode project, one SwiftUI codebase, three platforms. Share MahoNotesKit with CLI.
> iCloud is infrastructure (not an add-on) — the app needs it from day one for vault registry.
> UI design: **A (vault rail) + B (tree navigator) + C (content)** — see [app.md](app.md) for full spec.

### 4a — Xcode Project + iCloud Container + Vault Registry Sync ✅ (2026-03-05)

> Foundation: the app can launch, read vaults, and sync registry across devices.

- [x] Create Xcode project (Universal App: macOS + iOS + iPadOS targets) — XcodeGen `project.yml`
- [x] Add MahoNotesKit as local SPM dependency
- [x] App target: `Maho Notes.app`
- [x] Bundle identifier: `com.pcca.mahonotes`
- [x] Entitlements: iCloud Documents (`iCloud.com.pcca.mahonotes`), App Sandbox, network client
- [x] iCloud container: `iCloud.com.pcca.mahonotes`
  - Vault registry in container: `config/vaults.yaml`
  - iCloud vaults stored in container: `vaults/<name>/`
- [ ] `NSFileCoordinator` for safe reads/writes of vault registry + vault files (deferred — needed when iCloud is live)
- [x] `AppState` (`@Observable`): loads vault registry on launch, resolves vault paths per-platform (762 lines)
- [x] Basic `@main` App struct with `WindowGroup` + empty `NavigationSplitView` shell
- [x] Error state: if iCloud unavailable, auto-set Cloud Sync OFF → device vaults work (Decision #26)
- [x] CLI compatibility: macOS CLI reads the same iCloud container path (Package.swift: `.iOS(.v18)` added)
- [x] iOS compatibility: `#if os(macOS)` guards on Process/git CLI in Auth, GitSync, VaultInit
- [x] Cloud Sync toggle: `sync.cloud` setting (icloud | off), `device` vault type (Decision #26, c341104)
- [x] Onboarding overlay: speech bubble + glowing ＋ button when no vaults exist
- [ ] Tests: vault registry load/save via iCloud container mock (existing 229 tests pass, app-specific tests in 4b+)

### 4b — Core UI: Layout, Navigation, Tree Explorer 🔧 (2026-03-05, partial)

> The app can browse vaults, collections, and notes. Adaptive layout across all three platforms.
> Three-zone layout: **A (vault rail) + B (tree navigator) + C (content)** — no separate note list column.
> **Status:** Structural shell implemented (A+B+C layout, collapsible panels, basic views). Most sub-items need polish.

#### A — Vault Rail (~48pt wide, Slack-inspired) — `VaultRailView.swift` (182 lines)
- [x] Narrow vertical strip with rounded-square vault icons (first char + color background)
- [x] `＋` button (top): opens "Add Vault" flow
- [x] Active vault: highlighted with left accent bar
- [ ] Vault grouping: iCloud → GitHub (owned) → Read-only, separated by subtle dividers
- [ ] Read-only vaults: small 🔒 badge overlay on icon corner
- [ ] Scrollable when many vaults; author stays pinned at bottom
- [ ] Author + Settings (bottom, pinned): current vault's author initials + color; click → popover menu
- [ ] Author icon changes when switching vaults

#### B — Tree Navigator (~240pt, resizable, collapsible) — `NavigatorView.swift` (184 lines)
- [x] Collections tree with `DisclosureGroup` (tree nodes expand in-place to show notes)
- [x] **Recent** section: automatically populated
- [ ] B header: current vault icon + name (changes on vault switch); read-only vaults show 🔒
- [ ] Width: user-draggable (min 180pt, max 400pt), persisted per-window
- [ ] **Starred collections** section: user manually stars collections for quick access
- [ ] **Pinned notes** section: user-pinned notes (cross-collection quick access)
- [ ] Sections separated by subtle dividers with small uppercase labels
- [ ] SF Symbol icons for collections (from `maho.yaml`)

#### C — Content (remaining space) — `NoteContentView.swift` (188 lines)
- [x] Three view modes: Preview / Editor / Split (via `viewMode` state)
- [x] **Floating toolbar** (bottom-right): mode cycling (FloatingToolbarView.swift, 38 lines)
- [ ] C header: `◀ ▶` note history navigation + breadcrumb (clickable path segments) + `＋` new note (⌘N)
- [ ] **Smart tab bar**: appears only when editing + opening another note
- [ ] Edit mode formatting toolbar (B, I, H, 🔗, 🖼, ```, 📊, {|})
- [ ] Read-only vault: mode icon dimmed/disabled, formatting toolbar never appears

#### Collapsible Panels — `ContentView.swift` (377 lines)
- [x] A+B+C three-zone layout with collapsible panels (MacContentView)
- [x] Thin edge handle when collapsed: click to restore
- [x] Auto-collapse: width thresholds
- [x] ⌘⇧B, ⌘⇧A, ⌘\\ keyboard shortcuts
- [ ] Collapse state persisted per-window across app restarts

#### Title Bar — Search — `SearchPanelView.swift` (264 lines)
- [x] Search bar embedded in macOS title bar (NSViewRepresentable `TitleBarSearchField`)
- [x] ⌘K opens search panel dropdown
- [x] Scope picker (All Vaults / This Vault), mode picker (Text / Semantic / Hybrid)
- [x] Type-as-you-search with results list
- [ ] Empty state: recent searches + quick access (recently opened notes)

#### Platform Adaptation — `iPhoneContentView.swift` (223 lines)
- [x] macOS: A+B+C all visible (collapsible)
- [x] iPhone/iPad: tab-based navigation (iPhoneContentView)
- [ ] iPad landscape: same as macOS (A+B+C) — currently uses iPhone layout
- [ ] iPad portrait: A hidden, B as overlay sidebar
- [ ] iPad: Stage Manager multi-window support

- [ ] Tests: navigation state, vault/collection filtering, collapse state persistence, platform adaptation

### 4c — Markdown Rendering + Editor 🔧 (2026-03-05, partial)

> The heaviest sub-phase. The app can display beautifully rendered markdown and edit notes.
> **Status:** WKWebView rendering works (reuses SiteGenerator HTML). Basic TextEditor exists. Missing: TreeSitter, formatting toolbar, auto-save.

#### Rendering — `MarkdownWebView.swift` (291 lines, WKWebView approach)
- [x] CommonMark + GFM via WKWebView (reuses `MarkdownHTMLRenderer` from Phase 3)
- [x] Headings, bold, italic, code, links, blockquotes, tables, task lists, strikethrough
- [x] Ruby annotation: `{base|annotation}` → `<ruby>` HTML
- [x] Math (KaTeX): CDN-backed rendering in WKWebView
- [x] Mermaid diagrams: CDN-backed rendering in WKWebView
- [x] Admonitions / callouts: styled blocks via CSS
- [x] Code blocks: syntax highlighting via highlight.js CDN
- [ ] Code blocks with TreeSitter syntax highlighting → colored `AttributedString` (alternative to WKWebView)
- [ ] Images: local (`_assets/` relative path) — need file URL access in WKWebView
- [ ] Table of contents: auto-generated from headings, shown in sidebar or note header
- [ ] Footnotes: superscript link → footnote section at bottom

#### Editor — `NoteContentView.swift` (188 lines)
- [x] `TextEditor` with monospace font (configurable size via `@AppStorage`)
- [x] Three view modes: Preview / Editor / Split (via `viewMode` in AppState)
- [x] View mode toggle via FloatingToolbarView
- [ ] Markdown syntax highlighting in editor (currently plain monospace)
- [ ] Formatting toolbar: bold, italic, heading, link, image, code, table, ruby
- [ ] Auto-save: debounced (2s after last keystroke) — currently manual
- [ ] Frontmatter: shown as collapsible header (currently renders inline)
- [ ] Keyboard shortcuts: ⌘B bold, ⌘I italic, ⌘K link, ⌘N new note, ⌘S force save, ⌘E toggle, ⌘F in-note search

- [ ] Tests: markdown rendering correctness (each feature), view mode switching, auto-save

### 4d — Search UI + Settings 🔧 (2026-03-05, partial)

> In-app search (FTS5 + semantic + hybrid) and app configuration screens.
> **Status:** Search panel and Settings views implemented with core functionality. Missing: in-note search, GitHub OAuth in-app, search highlighting.

#### Search Results — `SearchPanelView.swift` (264 lines) + `AppState.performSearch()` (762 lines)
- [x] Results appear in ⌘K dropdown panel as you type
- [x] Scope picker (All Vaults / This Vault), mode picker (Text / Semantic / Hybrid)
- [x] Click result → navigate to note
- [ ] Each result: vault badge + collection path + snippet (partial — basic title/path shown)
- [ ] Source indicators for hybrid: `[text]`, `[semantic]`, `[text+semantic]`
- [ ] Search term highlighted in C panel on navigation
- [ ] Results grouped by vault when in "All Vaults" scope

#### In-Note Search (⌘F)
- [ ] Find bar at top of note content (Preview or Editor mode)
- [ ] Highlight matches, prev/next navigation
- [ ] Replace (Editor mode only)

#### Semantic Search Requirements
- [ ] Semantic / Hybrid modes only enabled when vector index exists — currently selectable but may fail silently
- [ ] If no index: show "Build search index" button
- [ ] Model download prompt if no embedding model cached

#### Settings — `SettingsView.swift` (435 lines, macOS) + `iOSSettingsView.swift` (289 lines, iOS)
- [x] **Vaults** tab: list of registered vaults, add (iCloud/Device/GitHub/Local), remove, set primary
- [x] **Search & Embedding** tab: model info, model picker, download button, rebuild index, index status
- [x] **Appearance** tab: theme (System/Light/Dark), font size, editor font
- [x] **About** tab: version, links
- [x] iOS Settings: Form-based `iOSSettingsView` (tabs: Vaults, Sync, Search, Appearance, About)
- [ ] **Cloud Sync** tab: toggle iCloud ON/OFF, migration UI (Decision #26 — designed, not yet in Settings UI)
- [ ] **Sync** tab: GitHub auth status, `ASWebAuthenticationSession` → OAuth → Keychain
- [ ] **Sync** tab: auto-sync toggle, manual "Sync Now", sync log per vault

- [ ] Tests: search result display, settings persistence, model download flow

### 4e — iCloud Sync: File Coordination + Conflict Resolution 🔧 (2026-03-05, partial)

> Full iCloud Documents sync for vault content. Real-time cross-device sync with conflict handling.
> **Status:** `iCloudSyncManager` implemented with NSMetadataQuery monitoring, conflict detection, and resolution. Missing: GitHub REST API sync, full UI for conflict resolution, NSFileCoordinator.

#### iCloud File Monitoring — `iCloudSyncManager.swift` (199 lines)
- [x] `NSMetadataQuery` with `NSMetadataQueryUbiquitousDocumentsScope` monitoring vault dirs
- [x] File change handling: detects updates via `NSMetadataQueryDidUpdate` / `DidFinishGathering`
- [x] Download-on-demand: `triggerDownload(for:)` calls `NSFileManager.startDownloadingUbiquitousItem`
- [x] Cloud-only placeholder detection (`isCloudOnlyPlaceholder`, `actualURL(from:)`)
- [x] Conflict detection: `NSFileVersion.unresolvedConflictVersionsOfItem` → `ConflictInfo` array
- [x] Conflict resolution: `resolveConflict(_:keeping:)` with `.keepCurrent` / `.keepConflict` options
- [x] UI integration: `NoteContentView` checks for `.icloud` placeholders and shows download state
- [ ] `NSFileCoordinator` for safe reads/writes (needed for multi-device correctness)
- [ ] Download progress shown for large files
- [ ] FTS/vector index update on file change (currently reloads notes list only)

#### Conflict Resolution UI
- [ ] ⚠️ badge on conflicted notes in B panel tree + note content
- [ ] Banner: "This note has a conflict" at top of note content
- [ ] Resolve view: side-by-side diff (remote left, local right)
- [ ] Actions: "Keep Remote", "Keep Local", "Keep Both" (rename local)

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

**Estimated effort:** ~10–14 sessions remaining (was 15–20 total, ~6 done)  
**Dependencies:** Phase 0, Phase 1 (multi-vault), Phase 2 (vector search for semantic toggle)  
**Tests:** UI tests + unit tests via MahoNotesKit  

**Sub-phase progress:**
| Sub-phase | Status | Remaining | Notes |
|-----------|--------|-----------|-------|
| 4a | ✅ done | — | Xcode, iCloud, Cloud Sync toggle, onboarding |
| 4b | 🔧 ~50% | 1–2 sessions | Shell exists; missing: vault grouping, starred/pinned, breadcrumb, iPad adaptation |
| 4c | 🔧 ~40% | 3–4 sessions | WKWebView rendering works; missing: syntax highlight editor, formatting toolbar, auto-save |
| 4d | 🔧 ~50% | 1–2 sessions | Search panel + Settings done; missing: in-note search, Cloud Sync tab, GitHub OAuth |
| 4e | 🔧 ~30% | 2–3 sessions | iCloudSyncManager exists; missing: NSFileCoordinator, conflict UI, GitHub REST API |
| 4f | ❌ 0% | 2–3 sessions | Share extension, ODR, Keychain, accessibility, polish |

---

## Phase Summary

| Phase | Description | Status | Dependencies |
|-------|-------------|--------|--------------|
| **0** | Code ↔ Design alignment | ✅ done (1 session) | None |
| **1** | Multi-Vault | ✅ done (1 session) | Phase 0 |
| **2** | Vector Search | ✅ done (1 session) | Phase 0, CJKSQLite compat |
| **2b-CLI** | Model management + `mn model` | ✅ done (1 session) | Phase 2 |
| **3.1–3.3** | Publishing (generator + commands) | ✅ done (1 session) | Phase 0, 1 |
| **3.4** | Our instance (notes.pcca.dev) | 🔧 needs DNS/Pages setup | Phase 3.1–3.3 |
| **4a** | Xcode + iCloud + Cloud Sync | ✅ done (1 session) | Phase 0, 1 |
| **4b** | Core UI layout | 🔧 ~50% (1–2 sessions left) | Phase 4a |
| **4c** | Markdown rendering + editor | 🔧 ~40% (3–4 sessions left) | Phase 4b |
| **4d** | Search UI + settings | 🔧 ~50% (1–2 sessions left) | Phase 4b |
| **4e** | iCloud sync + conflicts | 🔧 ~30% (2–3 sessions left) | Phase 4a |
| **4f** | Platform polish | ❌ (2–3 sessions) | Phase 4b–4e |

**Total estimated: ~10–14 sessions remaining**

### Parallelizable Work
- Phase 3 (Publishing) can run in parallel with Phase 4a–4c — no dependency between them
- Phase 4 sub-phases must be done in order (each builds on the previous)

### Heartbeat-Friendly Tasks
Each sub-item (e.g., 0.1, 4b, 2.3) is scoped to be completable in a single session. Sub-items within a phase should be done in order (they build on each other). Phases can overlap where dependency arrows allow.

---

*Plan by 真帆 🔭 — 2026-03-05, updated 2026-03-06*
