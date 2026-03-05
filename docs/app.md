# Native App (Universal, SwiftUI)

> One Xcode project, one SwiftUI codebase, three platforms (macOS + iPadOS + iOS).
> Shares MahoNotesKit with the CLI — all core logic (CRUD, search, sync, embedding) lives in the package.
> iCloud is infrastructure, not an add-on — the app needs it from day one for vault registry sync.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Maho Notes.app (SwiftUI)                     │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    Views (SwiftUI)                          │ │
│  │  Sidebar  │  NoteList  │  NoteContent  │  Settings         │ │
│  └─────┬─────┴─────┬──────┴──────┬────────┴──────┬────────────┘ │
│        │           │             │               │              │
│  ┌─────▼───────────▼─────────────▼───────────────▼────────────┐ │
│  │              ViewModels (@Observable)                       │ │
│  │  AppState  │  VaultStore  │  NoteEditor  │  SearchVM       │ │
│  └─────┬──────┴──────┬───────┴──────┬───────┴──────┬──────────┘ │
│        │             │              │              │            │
│  ┌─────▼─────────────▼──────────────▼──────────────▼──────────┐ │
│  │                   MahoNotesKit                             │ │
│  │  Vault · Note · Collection · Config · SearchIndex          │ │
│  │  VaultRegistry · GitSync · VectorIndex · Chunker           │ │
│  │  EmbeddingProvider · FrontmatterParser · SiteGenerator     │ │
│  └─────┬──────┬──────┬──────────────────────────────┬─────────┘ │
│        │      │      │                              │           │
│    ┌───▼──┐ ┌─▼────┐ │ ┌───────────────┐   ┌───────▼─────────┐ │
│    │SQLite│ │FTS5  │ │ │swift-embeddings│   │iCloud Container │ │
│    │index │ │+CJK  │ │ │(MLTensor)      │   │(vaults.yaml +  │ │
│    │.db   │ │+vec  │ │ └───────────────┘   │ vault files)   │ │
│    └──────┘ └──────┘ │                      └────────────────┘ │
│                      │                                         │
│              ┌───────▼──────┐                                  │
│              │GitHub REST API│  (optional sync + publishing)   │
│              └──────────────┘                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **App launch** → `AppState` loads vault registry from iCloud container (`vaults.yaml`)
2. **VaultStore** resolves vault paths per-platform → loads `maho.yaml` from each vault → populates collections
3. **Views** observe `@Observable` ViewModels → UI updates reactively
4. **Note edits** → `NoteEditor` writes markdown → auto-save (debounced) → iCloud syncs automatically
5. **Search** → `SearchVM` queries MahoNotesKit `SearchIndex` (FTS5) / `VectorIndex` (semantic) / `HybridSearch` (RRF)
6. **GitHub sync** → GitHub REST API (not git CLI — iOS has no git), debounced push + periodic pull
7. **iCloud file changes** → `NSMetadataQuery` detects changes → `VaultStore` reloads → Views update

### Key Principles

- **MahoNotesKit is the single source of truth** — Views never touch files directly
- **ViewModels are `@Observable`** (Swift 5.9 Observation framework, not Combine `ObservableObject`)
- **Platform adaptation via `NavigationSplitView`** — one layout code, SwiftUI handles column collapse
- **No UIKit/AppKit unless necessary** — pure SwiftUI where possible; `WKWebView` only for KaTeX/Mermaid

---

## Phase 4a — Xcode Project + iCloud Container

> The app can launch, discover vaults, and show a basic shell. iCloud syncs vault registry across devices.

### Project Setup
- **Bundle ID**: `com.pcca.mahonotes`
- **Minimum deployment**: macOS 15.0 / iOS 18.0 / iPadOS 18.0
- **Entitlements**: iCloud Documents (`iCloud~com.pcca.mahonotes`), App Sandbox
- **Dependencies**: MahoNotesKit (local SPM), swift-argument-parser (transitive)
- **Targets**: macOS, iOS (universal — iPad + iPhone)

### iCloud Container
- Container: `iCloud~com.pcca.mahonotes`
- Registry path: `config/vaults.yaml` (synced across all Apple devices)
- Vault storage: `vaults/<name>/` (iCloud vaults live here)
- `NSFileCoordinator` for safe reads/writes of registry + vault files
- CLI compatibility: macOS CLI reads the same iCloud container path (`~/Library/Mobile Documents/...`)

### App Shell
- `@main` App struct with `WindowGroup`
- `AppState` (`@Observable`): loads vault registry on launch, resolves vault paths
- Empty `NavigationSplitView` with placeholder content
- Error state: if iCloud unavailable, show setup guidance (not a hard block — local-only mode works)

---

## Phase 4b — Core UI: Sidebar, Navigation, Note List

> The app can browse vaults, collections, and notes. Adaptive layout across all three platforms.

### Navigation Structure

```
┌──────────────┬──────────────┬──────────────────────────┐
│   Sidebar    │  Note List   │     Note Content         │
│              │              │                          │
│ ▼ All Vaults │ ★ Star      │  # 訓讀 vs 音讀          │
│              │   2026-03-03 │                          │
│ ▼ personal   │ Universe     │  Content here...         │
│   日本語 📚  │   2026-03-02 │                          │
│     grammar  │              │                          │
│     vocab    │              │                          │
│   天文 ✨    │              │                          │
│              │              │                          │
│ ▼ work       │              │                          │
│   meetings   │              │                          │
│              │              │                          │
│ 🔒 cheatsheets│             │                          │
│   git        │              │                          │
└──────────────┴──────────────┴──────────────────────────┘
```

### Platform Adaptation

| Platform | Layout | Behavior |
|----------|--------|----------|
| **macOS** | Three-column `NavigationSplitView` | Always visible sidebar; resizable columns |
| **iPad landscape** | Three-column split | Same as macOS; sidebar toggleable |
| **iPad portrait** | Two-column (sidebar overlay) | Sidebar slides over note list |
| **iPhone** | Single-column push | Vault list → Collection → Note list → Note |

All use the same `NavigationSplitView` — SwiftUI handles column collapse automatically based on size class.

### Sidebar (Column 1)
- **"All Vaults"** item at top — shows all notes across all vaults
- **Vault sections**: each vault as a collapsible section
  - Vault name + icon (from `maho.yaml`)
  - 🔒 badge on read-only vaults
  - Collection tree: `DisclosureGroup` for nested directories, SF Symbol icons
- **Vault picker** (compact): on iPhone, vaults shown as section headers

### Note List (Column 2)
- Filtered by selected vault + collection
- Sort options: by updated date (default), title, custom order
- Note row: title, date, first-line preview, tags as pills
- Swipe actions: delete (read-write vaults only), pin/favorite
- Search bar at top (in-list filter, distinct from global search)

### Note Content (Column 3)
- Placeholder until Phase 4c (shows raw markdown text as fallback)

---

## Phase 4c — Markdown Rendering + Editor

> The app can display beautifully rendered markdown and edit notes. This is the heaviest sub-phase.

### View Modes

Three modes, toggled via toolbar button or ⌘E:

| Mode | Description | Platforms |
|------|-------------|-----------|
| **Preview** (default) | Rendered markdown, read-only | All |
| **Editor** | Raw markdown with syntax highlighting | All |
| **Split** | Editor left, live preview right | macOS, iPad landscape |

On iPhone: toggle between Preview and Editor (no split — not enough width).

### Markdown Rendering

Native SwiftUI rendering via `swift-markdown` parser → custom `AttributedString`:

| Feature | Rendering Approach |
|---------|-------------------|
| CommonMark + GFM | `AttributedString` (headings, bold, italic, links, tables, task lists, strikethrough) |
| Code blocks | TreeSitter syntax highlighting → colored `AttributedString` |
| Ruby annotation | `{base|annotation}` → custom `AttributedString` attribute → SwiftUI `rubyAnnotation` view |
| Images | Local (`_assets/` relative path) or remote URL → `AsyncImage` |
| Math (KaTeX) | `WKWebView` inline (delegated rendering — too complex for pure `AttributedString`) |
| Mermaid diagrams | `WKWebView` inline |
| Admonitions | Styled blocks (colored border + icon: tip 💡, warning ⚠️, note 📝, info ℹ️) |
| Table of contents | Auto-generated from headings, shown in sidebar or note header |
| Footnotes | Superscript link → footnote section at bottom |

### Editor

- **TextEditor** with monospace font and markdown syntax highlighting
- Toolbar: bold (**B**), italic (*I*), heading (H), link (🔗), image (🖼), code (```), table, ruby `{|}`
- Auto-save: debounced (2s after last keystroke), writes via MahoNotesKit
- Frontmatter: shown as a collapsible header (not raw YAML in editor by default)
- Keyboard shortcuts:
  - ⌘B bold, ⌘I italic, ⌘K link
  - ⌘N new note, ⌘S force save, ⌘E toggle edit mode
  - ⌘F in-note search, ⌘⇧F global search

---

## Phase 4d — Search UI + Settings

> In-app search (FTS5 + semantic + hybrid) and app configuration screens.

### Search

#### Global Search (⌘⇧F)
- Full-screen search overlay (or sheet on iPhone)
- Search bar with mode picker: **Text** (FTS5) · **Semantic** · **Hybrid**
- Cross-vault by default; optional vault/collection scope filter
- Results: vault badge + collection path + title + snippet (best-matching chunk for semantic)
- Source indicators for hybrid: `[text]`, `[semantic]`, `[text+semantic]`
- Tap result → navigate to note with search term highlighted

#### In-Note Search (⌘F)
- Find bar at top of note content (Preview or Editor mode)
- Highlight matches, prev/next navigation
- Replace (Editor mode only)

#### Semantic Search Requirements
- Only available when vector index exists for the vault
- If no index: show "Build search index" button → runs `VectorIndex.buildIndex()` in background
- Model download prompt if no embedding model cached

### Settings

Organized as a standard Settings view (macOS: Preferences window; iOS: NavigationStack):

#### Vaults
- List of registered vaults (from registry)
- Add vault: iCloud (new) / GitHub (repo URL) / Local (macOS only, directory picker)
- Remove vault (with confirmation; `--delete` option to also delete local files)
- Set primary (default vault)
- Per-vault info: type, access, GitHub repo, last sync time

#### Sync
- GitHub auth status (signed in / not signed in)
- Sign in: `ASWebAuthenticationSession` → GitHub OAuth → token stored in Keychain
- Auto-sync toggle (for GitHub-backed vaults)
- Manual sync button ("Sync Now")
- Sync log / last sync timestamp per vault

#### Search & Embedding
- Current embedding model: name, size, dimension, download status
- Model picker: MiniLM (default) / E5-Small / E5-Large
- Download button with `ProgressView` (show size + estimated time)
- "Rebuild Index" button (equivalent to `mn index --full`)
- Index status: last built, number of notes indexed, model used

#### Appearance
- Theme: System / Light / Dark
- Font size: slider or presets (Small / Default / Large)
- Editor font: system monospace or custom

#### About
- Version, build number
- Links: GitHub repo, docs, feedback

---

## Phase 4e — iCloud Sync: File Coordination + Conflict Resolution

> Full iCloud Documents sync for vault content. Real-time cross-device sync with conflict handling.

### iCloud File Monitoring

```
NSMetadataQuery (background)
    │
    ▼ file changed / added / deleted
VaultStore.handleFileChange()
    │
    ├── New note → add to note list, queue for FTS indexing
    ├── Modified note → reload content, update FTS index, mark for re-embedding
    ├── Deleted note → remove from list + indexes
    └── Conflict detected → create .conflict file, show ⚠️ badge
```

- `NSMetadataQuery` with `NSMetadataQueryUbiquitousDocumentsScope`
- Monitors all vault directories in iCloud container
- Handles download-on-demand: lazy files show placeholder → download triggered on access
- Download progress shown for large files (e.g., `_assets/`)

### Conflict Resolution UI

When iCloud detects a conflict (`NSFileVersion`):

1. **Badge**: ⚠️ icon on the note in sidebar + note list
2. **Banner**: "This note has a conflict" at top of note content
3. **Resolve view**: side-by-side diff
   - Left: remote version (current `note.md`)
   - Right: local version (`note.conflict-{timestamp}-local.md`)
   - Actions: "Keep Remote", "Keep Local", "Keep Both" (rename local)
4. **Resolution**: chosen version becomes `note.md`, conflict file deleted

### GitHub Sync from App

iOS has no `git` CLI — all GitHub operations via REST API:

| Operation | Implementation |
|-----------|---------------|
| Clone | GitHub API: get tree → download files |
| Pull | Compare HEAD → download changed files |
| Push | Create blobs → create tree → create commit → update ref |
| Auth | `ASWebAuthenticationSession` → OAuth token → Keychain |

**Sync ordering**:
1. iCloud settles first (local filesystem)
2. GitHub sync runs against settled local state (debounced 30s)
3. Never race iCloud and GitHub simultaneously

**Auto-sync behavior** (when enabled in Settings):
- **Push**: on note save, debounced 30s after last edit
- **Pull**: on app launch + every 5 min + pull-to-refresh (iOS)
- **Conflict on pull**: same resolution as iCloud conflicts (split into two files)

---

## Phase 4f — Platform Polish + iOS Extras

> From "it works" to "it's good." Platform-specific features and final polish.

### Share Extension (iOS / iPadOS)

- Separate target: `Maho Notes Share Extension`
- Accepts: text, URLs, images, PDFs
- UI: vault picker + collection picker + title field + preview
- Creates new note via MahoNotesKit (shared App Group container)
- Text → markdown body; URL → link with title; Image → saved to `_assets/`

### On-Demand Resources (ODR) — Embedding Models

- App Store binary ships with NO embedding models (keep under 200MB)
- Models tagged as ODR resources:
  - Tag `model-minilm`: all-MiniLM-L6-v2 (~90MB)
  - Tag `model-e5small`: multilingual-e5-small (~470MB)
  - Tag `model-e5large`: multilingual-e5-large (~2.2GB)
- Download triggered from Settings → Search → Embedding Model
- `ProgressView` shows download progress
- Fallback: if ODR unavailable (TestFlight, sideloaded), download from HuggingFace Hub directly

### Keychain (iOS / iPadOS)

- GitHub OAuth token stored in Keychain (not UserDefaults — sensitive)
- Shared Keychain access group for Share Extension
- macOS app also uses Keychain (consistent with iOS; CLI uses `~/.maho/config.yaml`)

### Platform-Specific Polish

| Feature | Platform | Notes |
|---------|----------|-------|
| Pull-to-refresh | iOS / iPadOS | Triggers GitHub sync |
| Keyboard shortcuts | iPad (external KB) | Same set as macOS |
| Stage Manager | iPadOS | Multiple windows support |
| Drag & drop | macOS, iPadOS | Drag notes between collections; drop files to attach |
| Menu bar | macOS | Quick note creation (optional, if needed) |
| Spotlight / Siri Shortcuts | iOS, macOS | Index notes for system search (future) |

### Universal Polish

- **Accessibility**: VoiceOver labels, Dynamic Type, reduce motion
- **App icon**: designed (TBD — SF Symbol placeholder during dev)
- **Launch screen**: app name + icon (minimal)
- **Onboarding**: first-launch flow — sign in to iCloud, create/import vault, optional GitHub auth
- **Offline mode**: graceful degradation — hide sync UI, show "offline" indicator, all local operations work
- **Error handling**: user-friendly error messages (not raw Swift errors), retry buttons for network failures

---

## Effort Estimates

| Sub-phase | Sessions | Key Deliverables |
|-----------|----------|-----------------|
| **4a** | 1–2 | Xcode project, iCloud container, vault registry, app shell |
| **4b** | 2–3 | NavigationSplitView, sidebar, note list, platform adaptation |
| **4c** | 4–6 | Markdown rendering (TreeSitter, KaTeX, Mermaid, ruby), editor, view modes |
| **4d** | 2–3 | Global/in-note search UI, settings screens, model management UI |
| **4e** | 3–4 | NSMetadataQuery, conflict resolution UI, GitHub REST API sync |
| **4f** | 2–3 | Share Extension, ODR, Keychain, accessibility, onboarding |
| **Total** | **15–20** | Universal app, full feature set |

**Dependencies**: Phase 0 + 1 (multi-vault) + 2 (vector search) must be complete before starting.
**Parallelizable**: Phase 3 (Publishing) can run alongside Phase 4a–4c.

---

*Design by 真帆 🔭 — 2026-03-05*
