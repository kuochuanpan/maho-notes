# Changelog

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
