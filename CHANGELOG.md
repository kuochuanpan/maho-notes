# Changelog

## [1.0.3] — 2026-11-09

TestFlight build 4. CLI `mn` 1.0.3 released through Homebrew on 2026-11-10 (`brew install mahopan/tap/mn`).

### 📱 iPhone Duo
- **Full screen on both displays** — the app now requires the iOS 27.1+ SDK (Xcode 27.1 or later), which removes the empty strip a 27.0-SDK build leaves along the right edge of Duo's outer and inner displays.
- **Bottom toolbar moves to the right edge** — where Duo lays bars out vertically (closed, and open in landscape), the iPhone layout's floating toolbar (New Note, New Collection, Sync, Settings) and the note's view-mode pill become system toolbar items in the trailing vertical bar. Other iPhones and iPads keep the floating toolbar.
- **Even columns when half open** — partially folded like a book, the navigator column ends exactly on the fold so the list side and the note side are the same width.
- See decision #31; `scripts/verify-duo.sh` lists what to check in each pose.
- **Fixed after TestFlight build 4** (found on a real iPhone Duo):
  - *Half open looked like fully open.* Build 4 waited for the system to mark the fold's reserved region active, which only happens once the hinge has settled, so a hand-held device never split. The split now follows the hinge angle itself (engages at ≤ 160°, releases above 170°) and still honors the system's fold region.
  - *Search stayed at the bottom of the left panel.* On the inner display, search now sits in the trailing vertical bar with the other controls; results still list in the navigator.
  - *Vault rail flickered in and out with the fold.* The inner display now starts with navigator + note (the layout the split view settles on at that width), so folding only moves the divider; the sidebar button still brings the rail in.

### 🗂 Vault registry
- **Vaults no longer disappear from every device** — a device that couldn't see the shared iCloud registry (not downloaded yet on a fresh install, or deleted by the old test suite) treated it as missing, registered the Getting Started tutorial into an empty registry, and saved that over the real one. Every device then lost its vault list (the vault folders stayed on disk). Now:
  - An iCloud registry that exists but isn't downloaded (`.vaults.yaml.icloud` placeholder) or can't be decoded counts as present. Loads throw `VaultRegistryError.iCloudRegistryUnavailable` instead of returning nothing, and `checkCloudRegistryExists` reports `.cloudRegistryUnavailable`.
  - Code that loads the registry in order to save it (`registerVault`, `registerVaultEntry`, vault remove / set primary / rename, disabling Cloud Sync) uses `loadRegistryForUpdate()`. That load aborts on an unreadable iCloud registry and no longer starts from an empty registry when a load fails. When the iCloud registry is truly gone, it builds on the cached vault list.
  - First launch adopts iCloud instead of installing the tutorial while the iCloud registry is still downloading. Turning Cloud Sync on in that state leaves it off and shows a notice under the picker (localized in all 7 languages).
  - After first-launch adoption, only the local cache is rewritten, never the iCloud registry.
- **Getting Started no longer shows up empty on other devices** — turning Cloud Sync on skipped any `.device` vault whose folder already existed in iCloud, so the shared registry kept a `.device` entry pointing at a folder only one device had. Migration now copies in the local files iCloud lacks (never overwriting) and converts the entry to `.icloud`. With Cloud Sync on, the bundled tutorial is installed into iCloud as an `.icloud` vault. On launch, the app repairs existing `.device` entries that have no local folder but a vault in iCloud.

### 🔎 Find Missing Items
- **Settings › Vaults › Find Missing Items…** (macOS and iOS) lists what's on this device but doesn't show up. Each row with a fix is checked by default; **Fix Selected** applies the checked ones, reloads, and scans again. Nothing is deleted.
  - **Vaults not in your list** — folders with a `maho.yaml` in iCloud `vaults/` (while Cloud Sync is on) or in this device's `vaults/` that aren't registered. A repo in `maho.yaml` makes it a GitHub vault, and its repo is filled in. With Cloud Sync on, a device vault is copied into iCloud before it's added. Folders whose name is already registered are skipped: they're leftovers from moving a vault between this device and iCloud.
  - **Collections** — a folder with notes that `maho.yaml` doesn't list (fix: add it, keeping every other key). A collection `maho.yaml` lists without a folder (fix: create the folder). An unreadable or not-yet-downloaded `maho.yaml` is reported, and its collections are skipped so no fix can overwrite it.
  - **Notes the app can't show** — notes at the vault root (fix: move into an `unsorted` collection). `.markdown`/`.MD`/… files (fix: rename to `.md`). UTF-16/32 files (fix: convert to UTF-8; other encodings are only reported). Notes iCloud hasn't downloaded (fix: download). README/LICENSE/CHANGELOG at a vault root, `_`-prefixed folders and READMEs aren't flagged.
- **CLI:** `mn vault find [--vault <name>] [--fix] [--json]` runs the same scan; `mn skill` documents it.
- Kit: `VaultStore.findMissingItems(vaultName:)`, `VaultStore.addFoundVault(_:)`, `Vault.findIssues()`, `Vault.fix(_:)`; 33 new UI strings in all 7 languages.

### ⌨️ CLI — writing notes from scripts and AI agents
- **Write a whole note in one call** — `mn new` takes the body from `--body`, `--stdin` (heredoc) or `--file`, and puts a `# Title` heading above it unless the body has one (`--no-heading` to skip). `--series` sets the series, and `--author` now defaults to `author.name` from the vault config instead of a hard-coded name.
- **New commands**
  - `mn write <path>` replaces a note's body, or adds to it with `--append` (a list item appended to a list continues the list; anything else starts a new paragraph).
  - `mn edit <path> --find <text> --replace <text>` changes part of a body. The text must match exactly once unless `--all` is given.
  - `mn move <path> --to <collection>` (alias `mv`) moves a note, its ordering entry and the assets it references.
- **`mn meta` rewrites only the fields it is asked to change.** `--unset <field>` removes one, `--add-tag` / `--remove-tag` accept comma-separated tags, values are checked per field (`public` / `draft` must be `true` or `false`, `order` a whole number, a title like `2024` stays text), and a change that would leave the frontmatter unreadable is refused before anything is written. A note with no frontmatter gets one.
- **Mistakes are errors, not files**
  - A collection that doesn't exist is `collection_not_found` (it used to be created silently, so a typo started a new collection). `--create-collection` makes one, and a new top-level collection is added to `maho.yaml`.
  - Note and collection paths cannot leave the vault: `mn new --collection ../x` used to write outside it.
  - `--if-exists suffix|error|skip` on `mn new`; `skip` returns the existing note, so a retried call does not leave `title-1.md` behind.
  - A wrong note path fails with the closest existing paths (same filename in another collection, a title instead of a filename, a typo).
  - Paths are spelled as they are on disk, so `Notes/A.md` and `notes/a.md` are one note; a symlinked folder cannot lead a write out of the vault; `_index.md` cannot be written or deleted as a note under any capitalization.
  - `mn write --stdin` / `--file` with empty input is refused (`missing_body`), so a failed pipe cannot blank a note. `--body ""` clears a body on purpose.
- **Machine-readable errors** — with `--json`, a failure prints `{"error": {"code", "message", "hint", "suggestions"}}` on stdout and exits non-zero. Without it the message goes to stderr (it used to go to stdout). `mn skill` lists the codes. ⚠️ `mn sync --json` failures use the same shape now; they used to print `{"error": "<text>"}`.
- **Smaller, more useful output**
  - `mn list --json` returns metadata without note bodies (`--body` puts them back). ⚠️ Scripts that read `body` from `mn list --json` need `--body`, or `mn show <path> --json`.
  - `mn list` gains `--sort updated|created|title`, `--limit`, a working `--series` filter, nested paths for `--collection`, and follows the `_index.md` order the app shows.
  - `mn new`, `write`, `edit`, `meta`, `move` and `delete` return `{"action", "path", "absolutePath", "note"}`; `mn show --json` includes `absolutePath`; `mn meta <path> --json` returns metadata only; `mn delete` accepts `--json`.
  - Note paths may omit `.md` or be absolute paths inside the vault. `absolutePath` is absolute even with a relative `--vault`.
  - `mn config set` accepts `--json`.
  - JSON no longer escapes `/` as `\/`.
- **`mn search` finds notes written a moment ago** — keyword search brings its index up to date before each query, reading only files that changed. Before, the index was built once and only `mn index` refreshed it. `--limit` (default 10) now applies to keyword search too, ranked across vaults.
- **`mn skill` rewritten** — leads with the writing workflow and rules, documents the new commands, JSON shapes and error codes, and no longer describes `collections.yaml` or numeric filename prefixes.
- **One JSON document per run** — `mn index --model <typo>` fails before indexing instead of after printing the keyword-index result; `mn publish` / `mn unpublish` print their result after the git push, so a failed push is the only output; usage errors (a bad flag value) are JSON too when `--json` is present, still with exit status 64.
- **`mn index`** skips the vector index with a note on stderr when the configured model is one this version no longer has (an old `builtin`), instead of failing after the keyword index. **`mn sync --all`** exits non-zero when any vault failed.
- **swift-argument-parser 1.7.0 → 1.8.2.**

### 🩹 Note corruption fixes (CLI and app)
- **Frontmatter survived only one edit** — `mn meta`, `mn publish <path>` and `mn unpublish` dropped the line break after the closing `---` on every write. The second write produced `---# Title`, after which the note had no readable frontmatter (title fell back to the filename; tags and dates were gone).
- **`_index.md` with a description lost its title and order** — the same dropped line break in the ordering writer, which runs whenever a note is created, moved or reordered (drag & drop in the app included). By the third write only the latest entry was left.
- **`_index.md` is edited, not regenerated** — writing a collection's order now changes only the `order:` / `children:` lines. Comments, key order and every other field stay as written, and an `_index.md` whose frontmatter no longer parses as a whole (an old unquoted title) keeps its title, order and sub-collections instead of being reduced to the newest entry.
- **A filename listed twice in `order:` crashed the sort** used by the app's navigator and by `mn list`. The first position now wins, and moving a note no longer adds a second entry for a filename the target already lists.
- **`---` inside frontmatter or at the top of a plain note** — an indented `---` inside a block value (`description: |`) no longer ends the frontmatter, and a note that has no frontmatter but opens with a `---` rule is read as all body rather than having its first paragraph treated as metadata.
- **Renaming a note whose title spans several lines** (`title: |`) left the old lines under the new title and broke the frontmatter; the whole entry is replaced now. Same for sub-collection titles.
- **Moving or copying a note could take a file from outside the vault with it** — an asset link written as `_assets/../../file` was followed. Such links are ignored when assets are moved, copied or checked for orphans.
- **`mn meta` rewrote every field** — a block-style tag list kept its `- item` lines under the new inline list, `created` was rewritten in a different date format, and quoted values lost their quotes.
- **Titles and tags with YAML syntax in them** — `Plan: Q4`, `#1`, `[draft]`, `true` and the like are now quoted wherever a title, tag, author, order entry or collection name is written: new notes, renaming a note or sub-collection, creating a sub-collection, pasting a copied note, `_index.md` titles and order lists, and the author name in a new vault's `maho.yaml`.
- **Titles with no letters or digits** (emoji only) created a hidden `.md` file; the note is now `untitled.md`. Very long titles are cut to a filename the filesystem accepts, and a note titled "README" becomes `readme-note.md` (`readme.md` is never listed as a note).
- **Timestamps follow the Gregorian calendar** regardless of the system calendar setting (a Buddhist or Japanese calendar wrote the wrong year into `created` / `updated`).
- **CRLF line endings** — notes saved with Windows line endings now have their frontmatter read.
- **Search index re-indexed unchanged notes** — a rounding difference in the stored modification time made unchanged notes look modified, so `mn index` re-indexed them. A file replaced by one with an older timestamp (restored from a backup, checked out by git) is now re-indexed as well.
- Kit: `FrontmatterDocument`, `YAMLFormat`, `noteTimestamp()`, `NoteError`, `Vault.createNote(…body:…)`, `writeNoteBody`, `replaceInNoteBody`, `updateNoteMetadata`, `deleteNote`, `resolveNotePath`, `SearchIndex.refresh(from:)`.

### 🧪 Tests
- **Test suite no longer touches live user data** — `Auth` takes an injectable `globalConfigDir`, and `VaultStore` / the registry functions take an injectable iCloud Documents base. `AuthTests` used to overwrite the real GitHub token in the App Group `config.yaml`, and `VaultStoreTests.cleanupRemovesCache` used to delete the device-synced iCloud `config/vaults.yaml`; both now use temp dirs. `cacheFileWrittenOnSaveWhenCloudOn` is re-enabled, and new tests cover a real `storeToken` round-trip and cloud-mode registry I/O against the injected iCloud base.
- 69 new library tests for the above, and a new `mnTests` target (20 tests) that runs the built `mn` binary end to end against throwaway vaults and home directories.

## [1.0.2] — 2026-10-09

TestFlight build 3.

### 🛠 Xcode 27 / iPhone 18 / iPhone Duo
- **Builds with Xcode 27.0** (iOS 27 / macOS 27 SDKs, Swift 6.4) with a clean warning baseline; verified on the iPhone 18 Pro simulator.
- **iPhone Duo ready (27.0 SDK level)** — iPhone orientations and `UIRequiresFullScreen = NO` declared explicitly, keyboard toolbar no longer sized from `UIScreen.main`, and device-name lookups made main-actor safe for the iOS 27 `UIDevice` isolation. Full Duo adoption (Device Hub poses, vertical toolbar, fold reserved regions) waits for Xcode 27.1 — see decision #30.
- **Verified on the iPhone Duo simulator** — `scripts/verify-duo.sh` builds with Xcode 27.1+ (27.2 beta used), runs on the iOS 27.1 runtime (the iOS 27.2 beta runtimes blacklist Duo), and screenshots both displays. With the 27.1+ SDK the app fills Duo's outer display instead of the 27.0 compatibility letterbox.
- **App unit tests runnable from `xcodebuild test`** — `MahoNotesTests` is attached to both app schemes with correct per-platform test hosts.
- **Xcode 27 MCP bridge** registered in `.mcp.json` for agent sessions.

## [1.0.1] — 2026-07-02

### 📄 Export
- **Export note to PDF** — an "Export as PDF" button in the note toolbar renders the note exactly as the in-app preview (math, code highlighting, Mermaid, ruby, images, admonitions). macOS saves via the standard save panel; iOS saves to Files / iCloud Drive. No new entitlements required.

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
