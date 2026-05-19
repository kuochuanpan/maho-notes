# Changelog

## [1.0.0] — 2026-05-19

**First App Store release.** Versions 0.3 through 0.8 shipped via TestFlight only; this entry summarizes everything since the last CHANGELOG entry (0.2.0).

### 🔍 Search & Embeddings
- **Cross-vault semantic search** — search across every registered vault from one bar; results carry a `vaultName` stamp and navigate to the correct vault on click
- **Cross-lingual ranking** — E5 query/passage instruction prefixes for higher-quality multilingual results
- **iOS search scope picker + multi-vault index build** — match the macOS experience on iPad and iPhone
- **Search-time UX** — model warm-up on app launch, loading indicator while embeddings come online, confirmation prompt before first enabling semantic search
- **Runtime memory shown per model** in Settings so users can pick a tier their device can afford

### 📱 iOS Stability & Memory (the long road)
The vector-index build was the dominant source of OOMs on iPhone/iPad. Resolved through a series of fixes:
- `autoreleasepool` around CoreML buffers; periodic model flush + unload between chunks
- Per-vault index build isolation so memory doesn't accumulate across vaults
- Compute policy switched to `cpuOnly` to eliminate the Metal memory-pool leak (also resolved an E5-large `SIGSEGV` on certain devices)
- iOS semantic-search errors now logged instead of swallowed by `try?`
- Aggressive nuke-and-rebuild path for corrupt `index.db` (with diagnostic logging)
- `vec0` table resilient drop; `.maho/` excluded from iCloud sync to keep index churn out of the cloud
- Model download cancellation no longer leaves partial state behind

### ☁️ iCloud Improvements
- **Auto-adopt iCloud vaults on first launch** (tutorial vault is skipped) + welcome overlay
- **Live registry change detection** — vaults appearing/disappearing from other devices show a reload indicator
- **Cross-vault navigation fix** — selecting a search result from another vault on iOS now switches vaults correctly
- **Merge conflict resolution** — properly renames vault directories on disk during merge

### 🎨 UI Polish
- macOS toolbar redesign — `unifiedCompact` style, smaller search field, reduced overall height
- Search bar with embedded scope and mode pickers
- Acknowledgments page listing all open-source dependencies
- Editor: confirmation flow before enabling memory-heavy features

### 🌐 Internationalization
- 7 locales: `en`, `zh-Hant`, `ja`, `ko`, `fr`, `it`, `es`
- 43 missing translations filled for the search / settings / vault management features added since 0.2.0
- 19 more translations filled for runtime-memory display, vault add sheet, cross-vault merge sheet, and code-block toolbar

### 🐛 Selected Bug Fixes
- Conflict resolution path bug + abort-on-failure during merge
- `wrap embedding` in `cpuAndGPU` compute policy preventing `EXC_BAD_ACCESS`
- Auto-recover from corrupt `index.db` during schema init
- Don't mark getting-started as installed when bundle resource is missing
- Delete vault files when removing a vault from the registry
- Read-only vault restrictions enforced across all UI surfaces
- Getting-started bundle uses `.bundle` packaging to avoid Xcode copy conflicts
- Use metadata `displayName` instead of folder name in new-note sheets

### 🏗️ Architecture & Tooling
- `swift-cjk-sqlite` bumped to 0.2.1 (vec pointer-safety fix)
- License changed from MIT to **PolyForm Noncommercial 1.0.0**
- README badges (version, license, Swift, platform, TestFlight)
- `CLAUDE.md` for AI-assisted contributors

### 📦 Versioning
Marketing version aligned to `1.0.0` across `App/project.yml`, `Sources/mn/MahoNotes.swift`, `Sources/mn/Commands/SkillCommand.swift`, and the README badge. Build number (`CURRENT_PROJECT_VERSION`) remains `1` for the first App Store submission — increment per TestFlight upload.

## [0.2.0] — 2026-03-09

### 📱 iOS & iPadOS Support
- **iPad**: Full 3-column layout (VaultRail | Navigator | NoteContent) matching macOS
  - Custom sidebar toggle with 3-state cycle (all → doubleColumn → detailOnly)
  - Breadcrumb bar with inline toggle + action buttons
  - DisclosureGroup-based collection tree with sub-collections
- **iPhone**: Custom slide-over vault rail sidebar + NavigationStack push for notes
  - Bottom toolbar (New Note, New Collection, Sync, Settings)
  - Full note editing with auto-save on back navigation
- **Shared components**: NoteRowContent, CollectionRowContent, NoteRowActions (cross-platform)
- iOS Settings: Cloud Sync, GitHub Account, GitHub Sync, Search & Embedding, Appearance

### ☁️ iCloud Sync (Cross-Platform)
- iCloud sync now works on macOS, iOS, and iPadOS
- Dynamic iCloud container path resolution via `url(forUbiquityContainerIdentifier:)`
- NSFileCoordinator for safe concurrent YAML read/write
- Cloud sync merge sheet with conflict detection and device-name renaming
- Vault migration between device ↔ iCloud storage

### 🔗 GitHub Sync on iOS
- Device Flow OAuth (no client secret, App Store safe)
- Modal sheet UX: code display → auto-open browser → polling → auto-dismiss
- GitHubSyncManager + SyncCoordinator unified sync engine
- Auto-sync: debounce 30s, periodic 5min, scenePhase .active, manual Sync Now

### ⚔️ Conflict Resolution
- iCloud: NSFileVersion-based conflict detection and resolution
- GitHub: `note.conflict-{DeviceName}.md` naming + ⚠️ badge + banner
- Cross-process coordination: NSFileCoordinator (YAML), WAL (SQLite), git lock check, NSFilePresenter

### 🎨 UI & Theme
- NTHU Purple theme centralized in MahoTheme.swift
- Dark mode support (dark gray backgrounds for navigator/content columns)
- Visual icon picker sheet for collections
- Collection context menu: New Note, New Sub-Collection, Paste, Change Icon, Rename, Delete

### 🐛 Bug Fixes
- Fix collection swipe actions leaking into child note rows (DisclosureGroup propagation)
- Fix Settings "Set Primary" also triggering "Delete" (SwiftUI multi-button row)
- Fix iCloud sync completely broken on iOS (hardcoded macOS paths)
- Fix sub-collections invisible on iOS (/var → /private/var symlink)
- Fix duplicate title in MarkdownWebView
- Fix auto-save not triggering on iOS note switching
- Fix note rename not updating B column list
- Disable `allowsFullSwipe` on delete to prevent accidental deletion

### 🏗️ Architecture
- VaultStore Phase 1-3 refactor: unified actor for all vault persistence (28 new tests)
- 292 tests passing (CLI + Kit)
- XcodeGen fully automated project generation
- Bundle ID: `dev.pcca.mahonotes`, Team: K867NAPA93

## [0.1.0] — 2026-03-03

Initial release.
- macOS native app with 3-panel layout
- CLI (`mn`) with 17 commands
- FTS5 full-text search with CJK support
- Vector search with swift-embeddings
- Hybrid search (RRF fusion)
- GitHub sync via git CLI (`mn sync`)
- YAML-based vault registry
