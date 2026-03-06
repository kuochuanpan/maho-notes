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
- `AppState` (`@Observable`): checks Cloud Sync setting → loads vault registry from iCloud container (ON) or local storage (OFF) → resolves vault paths
- Empty `NavigationSplitView` with placeholder content
- Error state: if iCloud unavailable, auto-set Cloud Sync OFF → app works fully with `device` vaults (not a hard block)

---

## Phase 4b — Core UI: Layout, Navigation, Tree Explorer

> The app can browse vaults, collections, and notes. Adaptive layout across all three platforms.
> Design goal: **cleaner and more intuitive than Obsidian** — less chrome, more content, Slack-inspired vault switching.

### Layout Overview (macOS)

```
┌──────────────────────────────────────────────────────────────┐
│ (🔴🟡🟢)        [ 🔍 Search Maho Notes              ]       │  ← Title Bar
├──┬───────────────┬───────────────────────────────────────────┤
│＋│ 📓 Personal   │ ◀ ▶  ◀ japanese / grammar            ＋ │  ← B header / C header
│──│───────────────│──────────────────────────────────────────│
│  │ ★ STARRED     │                                          │
│📓│   📚 日本語   │ # 訓讀 vs 音讀                           │
│  │   ✨ 天文     │                                          │
│📔│───────────────│ 訓讀（くんよみ）是用日語固有の発音...     │
│  │ COLLECTIONS   │                                          │
│📕│ ▾ 📚 日本語   │ ## 音讀                                  │
│  │   ▾ grammar   │                                          │
│🔒│     001-訓讀  │ 音讀（おんよみ）是模仿漢字原來的         │
│  │     002-長音  │ 中文發音...                               │
│  │     003-小假名│                                          │
│  │   ▸ vocab     │                                          │
│  │ ▸ ✨ 天文     │                                          │
│  │───────────────│                                          │
│  │ ★ PINNED      │                                          │
│  │   Star ⭐     │                                       👁 │
│🧑│───────────────│                                          │
│KC│ RECENT        │                                          │
└──┴───────────────┴──────────────────────────────────────────┘
 A         B                          C
```

The layout has **three visual layers**:

| Layer | Content | Function |
|-------|---------|----------|
| **Title Bar** | Search bar (centered) | Global search (⌘K) |
| **Second Row** | B header (vault name) / C header (breadcrumb + nav) | Context awareness |
| **Content** | A (vault rail) + B (tree explorer) + C (note content) | Main workspace |

### A — Vault Rail (~48pt wide)

A narrow vertical strip inspired by Slack's workspace switcher.

```
┌──┐
│＋│  ← Add Vault button (top)
│──│  ← separator
│📓│  ← iCloud vaults
│📔│
│──│  ← subtle separator (1px line or spacing)
│📕│  ← GitHub vaults (owned, read-write)
│──│
│🔒│  ← Read-only vaults (GitHub public repos)
│  │
│  │  ← flexible spacer (pushes author to bottom)
│  │
│🧑│  ← Author + Settings (pinned to bottom)
│KC│
└──┘
```

- **＋ button** (top): opens "Add Vault" flow — iCloud (new) / GitHub (repo URL) / Local (macOS only)
- **Vault icons**: rounded square with first character of vault name + color background (like Slack)
  - Active vault: highlighted with left accent bar
  - Read-only: small 🔒 badge overlay on icon corner
- **Vault grouping**: iCloud → GitHub (owned) → Read-only, separated by subtle dividers (no labels)
- **Scrollable**: if too many vaults, the rail scrolls (author stays pinned at bottom)
- **Author + Settings** (bottom, pinned):
  - Shows current vault's author initials + color background (e.g., `KC` blue)
  - Changes when switching vaults (each vault has its own author from `maho.yaml`)
  - Click → popover menu:
    ```
    ┌─────────────────────┐
    │ 🧑 Kuo-Chuan Pan    │  ← current vault author
    │ ── personal vault ──│
    │                     │
    │ ⚙️ Vault Settings    │  ← current vault config
    │ 🔍 Search Settings   │
    │ 🎨 Appearance        │
    │ ───────────────────  │
    │ ℹ️ About Maho Notes  │
    └─────────────────────┘
    ```
  - If vault has no author set → show `?` or default icon

### B — Navigator (~240pt, resizable, collapsible)

**Width**: default ~240pt, user-draggable via divider between B and C. Min 180pt, max 400pt. Width persisted per-window across restarts. Drag handle: thin line between B/C, cursor changes to `col-resize` on hover (macOS) or shows drag affordance (iPad).

A **pure tree explorer** — collections expand in-place to show sub-collections and notes. No mode switching, no "back" button. Like Xcode's project navigator or Finder's sidebar.

**B Header**: shows current vault icon + name (from `maho.yaml` `title` field). Changes when switching vault in A rail. Read-only vaults show `🔒 Cheatsheets`.

**Tree Structure**:
```
┌───────────────┐
│ 📓 Personal   │  ← B header (vault name)
│───────────────│
│ ★ STARRED     │  ← user-starred collections (quick access, like Slack starred channels)
│   📚 日本語   │
│   ✨ 天文     │
│───────────────│  ← separator
│ COLLECTIONS   │  ← full collection tree (expand in-place)
│ ▾ 📚 日本語   │     click → toggle expand/collapse
│   ▾ grammar   │     sub-collections expand too
│     001-訓讀  │     notes appear as leaves → click → show in C
│     002-長音  │
│     003-小假名│
│   ▸ vocab     │     collapsed sub-collection
│   ▸ conversation│
│ ▸ ✨ 天文     │  ← collapsed collection
│ ▸ 🖥 模擬     │
│ ▸ 💻 software │
│───────────────│
│ ★ PINNED      │  ← user-pinned notes (cross-collection quick access)
│   Star ⭐     │
│   Neutrino 📝 │
│───────────────│
│ RECENT        │  ← recently edited notes (automatic, 5-10 items)
│   Universe    │
│   Grammar #3  │
│   模擬日誌 #12│
└───────────────┘
```

- **Starred collections**: user manually stars collections for quick access at the top
- **Collections tree**: `DisclosureGroup` with unlimited nesting depth, SF Symbol icons from `maho.yaml`
- **Pinned notes**: user manually pins notes (appear regardless of which collection is expanded)
- **Recent**: automatically populated, most recently edited notes (5-10 items)
- Sections separated by subtle dividers with small uppercase labels
- Entire B column scrolls freely

### C — Content (remaining space)

**C Header**: navigation arrows + breadcrumb + new note button.

```
┌──────────────────────────────────────────────────┐
│ ◀ ▶  ◀ japanese / grammar                    ＋ │
└──────────────────────────────────────────────────┘
  nav    breadcrumb (clickable segments)    new note (⌘N)
```

- `◀ ▶` — note history navigation (back/forward through visited notes)
- Breadcrumb — clickable path segments: `japanese` / `grammar` → click to navigate to that level
- `＋` — new note in current collection (⌘N)

**Smart Tab Bar** — appears only when needed:

```
Normal (no tab bar — clean):
┌──────────────────────────────────────────────────┐
│ ◀ ▶  ◀ japanese / grammar                    ＋ │
│──────────────────────────────────────────────────│
│                                                  │
│ # 訓讀 vs 音讀                                   │
│ ...                                              │

Editing note A, then open note B → tab bar appears:
┌──────────────────────────────────────────────────┐
│ ◀ ▶  ◀ japanese / grammar                    ＋ │
│ ┌─ ★ Star ●──┬─ Universe ✏️ ─┐                  │
│─┤            │               ├──────────────────│
│ │ # Star     │               │                  │
│ │ ...        │               │                  │
```

- **Default**: no tab bar (one note, maximally clean)
- **Tab bar appears when**: you're editing note A and click a different note B in B panel
  - Note A stays open in a tab (preserving unsaved changes)
  - Note B opens in a new tab
- **View-only click**: if note A is in view mode (no edits), clicking note B just replaces it (no tab created — nothing to preserve)
- **Tab indicators**: `✏️` = currently editing, `●` = unsaved changes (like VS Code / Xcode)
- **Closing tabs**: click × on tab; when ≤ 1 tab remains, tab bar disappears
- **No hard limit**: but tabs are context-preserving, not hoarding — most users will have 2-4

**Floating Toolbar** (bottom-right corner):

View mode (minimal — single icon cycles through modes):
```
┌─────┐
│ 👁  │  ← click to cycle: 👁 Preview → ✏️ Editor → ⊞ Split → 👁 Preview...
└─────┘
```

Edit mode (expanded — formatting tools appear):
```
┌──────────────────────────────────┐
│ B  I  H  🔗 🖼 ``` 📊 {|}  ✏️  │
│ bold italic heading link img code tbl ruby  mode │
└──────────────────────────────────┘
```

**View mode cycling**: single icon, click to advance. Icon changes to reflect current mode:
- 👁 = Preview (reading)
- ✏️ = Editor (writing)
- ⊞ = Split (side-by-side)

**Read-only vault**: mode icon shows 👁 with dimmed/disabled appearance (muted color, no hover effect). Click does nothing — read-only vaults are always in preview mode. Formatting toolbar never appears.

### Title Bar — Search

Search bar embedded in the macOS window title bar (like Slack):

```
┌──────────────────────────────────────────────────────────────┐
│ (🔴🟡🟢)        [ 🔍 Search Maho Notes              ]       │
└──────────────────────────────────────────────────────────────┘
```

Click search bar or press ⌘K → search panel drops down:

```
┌──────────────────────────────────────┐
│ 🔍 |                          ⌘K    │
│──────────────────────────────────────│
│ SCOPE: 🔘 All Vaults  ○ This Vault  │
│ MODE:  🔘 Text  ○ Semantic  ○ Hybrid│
│──────────────────────────────────────│
│ RECENT SEARCHES                      │
│   neutrino transport                 │
│   恆星怎麼死的                        │
│   ruby annotation                    │
│──────────────────────────────────────│
│ QUICK ACCESS                         │
│   📝 Star (personal/japanese)        │
│   📝 模擬日誌 #12 (work/simulation)  │
└──────────────────────────────────────┘
```

- **Default scope: All Vaults** (cross-vault search is a core feature — not hidden)
- Toggle scope to current vault
- Search mode: Text (FTS5, default) / Semantic / Hybrid (enabled when vector index exists)
- Type-as-you-search (debounced), results appear instantly
- Empty state: recent searches + quick access (recently opened notes)

### Collapsible Panels

Both A and B panels can be collapsed to maximize writing space:

```
Full (default):        B collapsed:           A+B collapsed (focus mode):
┌──┬─────┬────────┐   ┌──┬──────────────┐   ┌──────────────────────┐
│A │ B   │   C    │   │A │     C        │   │         C            │
│  │     │        │   │  │              │   │                      │
└──┴─────┴────────┘   └──┴──────────────┘   └──────────────────────┘
```

| Shortcut | Action |
|----------|--------|
| **⌘⇧B** | Toggle B (navigator) |
| **⌘⇧A** | Toggle A (vault rail) — also collapses B |
| **⌘\\** | Toggle focus mode (collapse A+B together) |

**UI Controls**:

| UI Element | Location | Action |
|------------|----------|--------|
| Sidebar toggle (`sidebar.left` SF Symbol) | B header, left side | Click: toggle B / Long-press: toggle A+B |
| Thin edge handle (~4pt) | Left edge when A/B collapsed | Click/tap: restore previous panel state |
| Focus icon (`arrow.up.left.and.arrow.down.right`) | C floating toolbar (optional) | Click: toggle focus mode (A+B) |

**Collapse behavior**:
- B collapsed → thin vertical line as handle on left edge of C; click handle or ⌘⇧B to restore
- A collapsed → B shifts to left edge; vault switching via dropdown in B header (shows vault icon + name, click for vault list); sidebar toggle remains in B header
- A+B collapsed → C fills entire window; thin handle on left edge; hover/tap to restore
- Sidebar toggle icon rotates or changes state to indicate collapsed panels
- Collapse state is remembered per-window (persisted across app restarts)

**Auto-collapse**: when window width < 900pt, B auto-collapses; < 600pt, A+B auto-collapse (like responsive breakpoints).

### Platform Adaptation

| Platform | A (Vault Rail) | B (Navigator) | C (Content) | Search |
|----------|---------------|---------------|-------------|--------|
| **macOS** | Visible (collapsible) | Visible (collapsible) | Fills remaining | Title bar search bar + ⌘K panel |
| **iPad landscape** | Visible (collapsible) | Visible (collapsible) | Fills remaining | Top toolbar search bar + ⌘K |
| **iPad portrait** | Hidden (vault dropdown in B header) | Overlay sidebar (swipe from left) | Full width | 🔍 icon in toolbar → sheet |
| **iPhone** | Hidden (vault dropdown in B header) | Full-screen push | Full-screen push | 🔍 in nav bar → full-screen search |

**iPhone adaptation**: A rail doesn't fit on phone — vault switching via a dropdown in B header. B panel is the root view; tapping a note pushes C full-screen.

**iPad adaptation**: In landscape, same as macOS (A+B+C). In portrait, A hides and B becomes a swipe-in overlay. Keyboard shortcuts work with external keyboard.

### vs. Obsidian

| Aspect | Obsidian | Maho Notes |
|--------|---------|------------|
| Sidebar | File explorer + search + bookmarks + tags + plugins (cluttered) | Vault rail + tree navigator (two clean layers) |
| Vault switching | Close app, reopen different vault | Click icon (like Slack workspace) |
| Tabs | Always visible tab bar | Smart tabs (appear only when editing + opening another note) |
| Settings | Dozens of pages, maze-like | One popover, 4 sections |
| Visual noise | Plugin icons, ribbons, status bars | Only vault icons + content |
| Search | Sidebar panel | Title bar (always accessible, app-level) |

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
  - ⌘F in-note search, ⌘K global search (opens title bar search panel), ⌘⇧F alias for ⌘K

---

## Phase 4d — Search UI + Settings

> In-app search (FTS5 + semantic + hybrid) and app configuration screens.

### Search

> Global search UI (title bar + ⌘K panel) is spec'd in Phase 4b. This section covers search result display and in-note search.

#### Search Results View
- Results appear in the ⌘K dropdown panel as you type
- Each result: vault badge + collection path + title + snippet (best-matching chunk for semantic)
- Source indicators for hybrid: `[text]`, `[semantic]`, `[text+semantic]`
- Click result → navigate to note with search term highlighted in C panel
- Results grouped by vault when in "All Vaults" scope

#### In-Note Search (⌘F)
- Find bar at top of note content (Preview or Editor mode)
- Highlight matches, prev/next navigation
- Replace (Editor mode only)

#### Semantic Search Requirements
- Semantic / Hybrid modes only enabled when vector index exists
- If no index: show "Build search index" button → runs `VectorIndex.buildIndex()` in background
- Model download prompt if no embedding model cached

### Settings

Organized as a standard Settings view (macOS: Preferences window; iOS: NavigationStack):

#### Vaults
- List of registered vaults (from registry)
- Add vault: iCloud (new, Cloud Sync ON only) / Device (app-managed local) / GitHub (repo URL) / Local (macOS only, directory picker)
- Remove vault (with confirmation; `--delete` option to also delete local files)
- Set primary (default vault)
- Per-vault info: type, access, GitHub repo, last sync time
- Migrate vault type: `device` ↔ `icloud` (with file copy + type update)

#### Cloud Sync
- **Toggle**: iCloud ON / OFF (per-device setting, stored in UserDefaults)
- When ON: vault registry + iCloud vaults stored in iCloud container, syncs across Apple devices
- When OFF: vault registry stored locally, `type: icloud` vaults unavailable (grayed out with explanation)
- **Switching ON → OFF**: warns "Other devices will no longer sync"; migrates `icloud` vaults to `device` type (copies files to local)
- **Switching OFF → ON**: migrates local registry to iCloud container; offers to convert `device` vaults to `icloud`

#### GitHub Sync
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
- **Onboarding**: first-launch flow:
  1. iCloud available? → "Enable iCloud Sync?" → Yes (Cloud Sync ON, `type: icloud`) / No (Cloud Sync OFF, `type: device`)
  2. iCloud unavailable → Cloud Sync OFF automatically, `type: device`
  3. Optional: "Connect GitHub for backup/sync?"
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
