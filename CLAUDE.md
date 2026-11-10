# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build, test, run

```bash
# CLI (Swift package)
swift build                          # debug build → .build/debug/mn
swift build -c release               # release build → .build/release/mn
swift run mn <subcommand> [args]     # run CLI without installing

# Tests — use the Swift Testing framework (`import Testing`, `@Suite`, `@Test`, `#expect`), NOT XCTest
swift test                                            # all tests
swift test --filter MahoNotesKitTests.VaultStoreTests # one suite
swift test --filter <TestName>                        # one test

# Universal app (macOS + iPhone + iPad) — Xcode project is regenerated, NOT checked in
cd App
xcodegen generate                    # rebuild MahoNotes.xcodeproj from project.yml
open MahoNotes.xcodeproj
# Target `MahoNotes` builds for both macOS and iOS (Mac/iPhone/iPad destinations); pick destination in Xcode.
```

> **Tests must never touch live data.** The defaults for `Auth(globalConfigDir:)` and `VaultStore(globalConfigDir:iCloudDocumentsBase:)` (and the `iCloudBase:` parameter on the registry free functions) are the real App Group container (holds the user's GitHub token) and the real iCloud container (`config/vaults.yaml` syncs to every device). Any test that stores a token, or switches sync mode to `.icloud` and then saves/loads/cleans up the registry, must inject temp dirs for both. Earlier suites skipped this and wiped the user's token and iCloud registry. To prove a run is clean, run `CFFIXED_USER_HOME=<tmp> swift test`, then check that the App Group files are unchanged and that `<tmp>/Library/Mobile Documents` was never created.

> **Building with a non-default Xcode (betas):** run `xcrun xcodebuild …` or `"$DEVELOPER_DIR/usr/bin/xcodebuild" …`, never a bare `xcodebuild`. If an Xcode's `Contents/Developer/usr/bin` is on PATH ahead of `/usr/bin` (home-manager's `home.sessionPath` did this on the build Mac), a bare `xcodebuild` is that Xcode's own binary and ignores `DEVELOPER_DIR`, while `xcrun` / `simctl` honor it — you silently get a 27.0-SDK binary on a 27.2 simulator. Confirm the SDK with `otool -l <binary> | grep -A5 LC_BUILD_VERSION`. `scripts/verify-duo.sh` does both.

The Xcode project (`App/MahoNotes.xcodeproj`) is gitignored — always run `xcodegen generate` after pulling or after editing `App/project.yml`. CI is currently disabled (`.github/workflows/ci.yml.disabled`).

### Distribution

**App — App Store.** The universal app is live on the App Store for macOS, iOS, and iPadOS: <https://apps.apple.com/us/app/maho-notes/id6760572212> (Apple ID `6760572212`). When cutting a release, bump **both** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `App/project.yml` — App Store Connect requires the build number to strictly increase across every upload, even for the same marketing version.

**CLI — Homebrew.** The CLI ships through a **separate tap repo** (`mahopan/tap`) — there is no formula in this repository. Releases of `mn` are built and tagged here, then the formula in the tap repo points at the tag's source tarball / binary.

```bash
brew tap mahopan/tap
brew install mn                      # formula is `mn` (Formula/mn.rb in mahopan/homebrew-tap)
```

The formula builds from the source tarball of a `v<version>` tag in this repo (`swift build -c release --product mn`), and its `test do` block checks `mn --version` against the formula version and `mn skill` for the "AI Agent Guide" heading. Releasing the CLI therefore means: push a `v<version>` tag here, then update `url` and `sha256` in the tap's `Formula/mn.rb`.

### Xcode MCP (Xcode 27, external-agent mode)

Xcode 27 exposes its tooling to external agents over MCP through `xcrun mcpbridge`. The repo's `.mcp.json` registers that bridge as the `xcode` server, so Claude Code sessions in this repo get Xcode's tools: `BuildProject` / `GetBuildLog`, `XcodeRefreshCodeIssuesInFile`, `RunAllTests` / `RunSomeTests` / `GetTestList`, `RunProject` / `GetConsoleOutput` / `StopProject`, `RenderPreview`, `RunCodeSnippet`, `DeviceInteraction*` (simulator screenshots + taps), `StringCatalog*` / `LocalizationPlanner`, `DocumentationSearch`, and project-structure file ops (`XcodeRead`, `XcodeGrep`, …).

- **Preconditions**: Xcode must be running, with Xcode > Settings > Intelligence > Model Context Protocol > "Allow external agents to use Xcode tools" turned on. `xcrun mcp-server status` reports the server state and any pending approval ids (`sudo xcrun mcp-server approve <id>` is the CLI fallback for the dialog).
- **First call every session**: `XcodeOpenWorkspace` with the absolute path to `App/MahoNotes.xcodeproj` (run `xcodegen generate` first if the project is missing). That call is what triggers Xcode's approval dialog for the agent and the project folder; until it is approved every other Xcode tool returns "This agent isn't approved to use Xcode's tools yet".
- **Schemes**: `MahoNotes_macOS` and `MahoNotes_iOS` (`XcodeListSchemes` / `XcodeSwitchScheme`, `XcodeListRunDestinations` / `XcodeSwitchRunDestination`). The app's own unit tests (`MahoNotesTests`) run through Xcode's test tools; `MahoNotesKit` / `mn` tests are SwiftPM — keep using `swift build` / `swift test` for those.
- **When to use which**: prefer the Xcode tools for anything about the app target (structured build errors, previews, running on a simulator, String Catalog edits). Plain `xcodebuild` from Bash still works and does not need Xcode running. The bridge is macOS-only and talks to the Xcode selected by `xcode-select` (override with `MCP_XCODE_PID`).
- **Apple's bundled skills** (swiftui-specialist, translation / translation-coordinator, device-interaction, modernize-tests, accessibility-*, …) ship as an Xcode-exported Claude Code plugin. Load them for a session with `claude --plugin-dir "$(xcrun agent plugin path --plugin-format claude)"`. That plugin declares the same bridge again (as `plugin:xcode-integration:xcode`), so expect a second server and possibly a second approval; disable one of the two under `/mcp` if that bothers you. The `StringCatalogEdit` tool refuses to run unless the `xcode-integration:translation` skill is loaded, so use the plugin for localization work.

## Architecture

Three artifacts share one Swift codebase:

- **`MahoNotesKit`** (`Sources/MahoNotesKit/`) — library. All persistence, search, sync, markdown rendering, site generation. Both the CLI and the app depend on this. *Mostly* platform-agnostic, but several Kit files (`Auth.swift`, `GitSync.swift`, `VaultInit.swift`, `VaultRegistry.swift`, `VaultStore.swift`) use `#if os(macOS)` to gate things like `Process` invocations, `gh` lookup paths, and `~/.maho` resolution — iOS uses the app's Documents directory instead. Keep that pattern when adding code that touches the filesystem or subprocesses.
- **`mn`** (`Sources/mn/`) — CLI executable using `swift-argument-parser`. One file per subcommand under `Sources/mn/Commands/`. New subcommands are registered in `Sources/mn/MahoNotes.swift`. **Version strings live in three places and must be kept in sync when releasing**: `App/project.yml` (`MARKETING_VERSION`), `Sources/mn/CLISupport.swift` (`mnVersion`, used by both `mn --version` and `mn skill --json`), and `README.md`'s version badge.
- **`MahoNotes` app** (`App/MahoNotes/`) — SwiftUI universal app, single target building for macOS 15+ and iOS/iPadOS 18+. Depends on `MahoNotesKit` via the local Swift package.

### macOS / iPad / iPhone split inside the app

The app target is universal, but each form factor has its own root view and the codebase uses `#if os(macOS)` / `#if os(iOS)` heavily to keep them apart:

| Form factor | Root view | Distinctive files |
|-------------|-----------|------------------|
| macOS | `ContentView.swift` | `SettingsView.swift`, `MacAddVaultSheet.swift`, `FloatingToolbarView` (macOS branch) |
| iPad | `IPadContentView.swift` | `IPadVaultRail.swift`, `IPadAddVaultSheet.swift` — 3-column layout matching macOS (vault rail / navigator / content) |
| iPhone | `iPhoneContentView.swift` | slide-over vault rail, `NavigationStack` push, bottom toolbar |
| iOS-shared (iPad + iPhone) | `iOSSettingsView.swift`, `DuoSupport.swift` | iOS-only settings UI (macOS uses `SettingsView.swift`); iPhone Duo helpers |
| cross-platform | `AppState.swift`, `NavigatorView.swift`, `NoteContentView.swift`, `MarkdownEditorView.swift`, `NoteRowContent.swift`, `CollectionRowContent.swift`, `NoteRowActions.swift` | shared between all three; conditional code inside |

When adding UI, prefer reusing the cross-platform views and gating only the bits that genuinely differ. iOS-only files start with `#if os(iOS)` at the top of the file — match that pattern instead of sprinkling per-view conditionals.

**iPhone Duo** routes through the same two iOS layouts by size class: the outer display (compact width) gets `iPhoneContentView`, the inner display (regular × regular) gets `IPadContentView`. The Duo-specific parts (decision #31) go through `DuoSupport.swift`, which wraps the iOS 27.1 APIs behind `#available`: `ToolbarVerticalEdgeReader` (non-nil where the system lays bars out vertically on the trailing edge — custom bottom bars must then hand their actions to system `.toolbar` items, because only standard bars move there), `onDuoHingeChange` (the hinge angle — the reliable "is it folded" signal; the fold's reserved region only turns active once the hinge settles, so a hand-held device never triggers it), `onDuoFoldChange` (where the fold runs), and `FoldAlignedNavigatorWidth` (pins the navigator column to the fold when partially open). Diagnostics log under category `duo`. The app therefore needs the **iOS 27.1+ SDK** to build; a 27.0-SDK build also letterboxes on Duo. Pose changes (Closed / Partially Open / Open) can only be made by hand in Device Hub — see `scripts/verify-duo.sh`.

**Entitlements** are a single file (`App/MahoNotes/MahoNotes.entitlements`) used for both platforms. It enables iCloud (CloudDocuments, container `iCloud.dev.pcca.mahonotes`), the `group.dev.pcca.mahonotes` app group, app sandbox, network client, app-scope bookmarks, and user-selected read/write. The stale comment in `project.yml` mentioning `MahoNotes_macOS.entitlements` / `MahoNotes_iOS.entitlements` does not reflect the current layout — there's only the one file.

**Tip Jar (StoreKit 2)**: `TipJarManager.swift` + `TipJarView.swift` drive consumable IAPs (`com.mahonotes.tip.small/medium/large`) wired through `App/MahoNotes/Products.storekit` (referenced by `scheme.storeKitConfiguration` in `project.yml`). Shown inside both `SettingsView` (macOS) and `iOSSettingsView` (iOS).

**Getting Started bundle**: `App/MahoNotes/Resources/GettingStarted.bundle/getting-started/` is shipped as an app resource. `GettingStartedBundler.swift` materializes it into a real vault on first run as the tutorial vault.

### VaultStore is the persistence boundary

`VaultStore` (actor, `Sources/MahoNotesKit/VaultStore.swift`) is the single entry point for all YAML/JSON reads and writes that touch vault state — registry, global config, per-vault config, paths. Older free functions (`loadRegistry`, `saveRegistry`, `resolvedPath`, …) still exist; `VaultStore` currently wraps them and is the migration target. **New persistence code should go through `VaultStore`, not the free functions.** See `docs/vault-store.md` for the RFC and the bugs the actor design exists to fix (path divergence, write-only cache, no concurrency safety).

### Search has three modes and one index

- FTS5 keyword search via `swift-cjk-sqlite` (CJK tokenizer for 中英日韓 inside the same SQLite file).
- Semantic search via `swift-embeddings` (HuggingFace Safetensors models, MLTensor runtime). Vectors live in the same SQLite DB via `sqlite-vec`. Models: `minilm` (default, ~80MB) / `e5-small` (~120MB) / `e5-large` (~2.2GB).
- Hybrid = RRF fusion (k=60, 1:1 weight). `--hybrid` without a vector index degrades to FTS5 with a warning.

Chunking strategy lives in `Chunker.swift`: heading-based splits, title prepended to each chunk, no overlap, no frontmatter. Note score = best chunk score. Models are downloaded on demand (ODR in App Store builds; HuggingFace Hub for CLI/sideloaded builds, cached in `~/.maho/models/`). NLEmbedding is intentionally not used — only English is supported by Apple's API (see decision #21).

### Vault types and sync

Four vault types, resolved by convention from the vault name (`Sources/MahoNotesKit/VaultRegistry.swift`):

| Type | Storage | Sync |
|------|---------|------|
| `.icloud` | iCloud container `Documents/vaults/<name>/` | iCloud (NSMetadataQuery + NSFileVersion conflicts) |
| `.device` | `~/.maho/vaults/<name>/` (macOS) or App Documents (iOS) | none; optional GitHub backup |
| `.github` | `~/.maho/vaults/<name>/` | GitHub: `git` CLI (macOS only) **or** REST API via `swift-github-api` (all platforms) |
| `.local` | user-specified path | none (macOS only) |

The CLI's `mn sync` uses the `git` CLI. The app uses `GitHubSyncManager` (REST API) on every platform — iOS has no git binary. Both paths produce the same `note.conflict-{DeviceName}.md` conflict files; resolution is manual. `SyncCoordinator` (app only) handles auto-sync: 30s debounce on push, 5min periodic pull.

The `Cloud Sync` toggle (per-device, never stored in iCloud) controls whether the vault registry lives in iCloud or locally. When OFF, `.icloud` vaults cannot be created and the registry falls back to `~/.maho/vaults.yaml`.

### Ordering and frontmatter

Note ordering uses `_index.md` files per directory (NOT numeric filename prefixes — that approach was replaced; see decision #27). Each `_index.md` has `order:` (note filenames) and `children:` (sub-collection names) in frontmatter. Files not listed in `order:` are appended alphabetically. Top-level collection ordering is in `maho.yaml`'s `collections:` array. Drag & drop in the app writes to `_index.md`.

Ruby annotations use `{base|annotation}` syntax (language-agnostic — Japanese furigana, Tâi-lô, Zhuyin, Korean readings), rendered as HTML `<ruby>` on web and `AttributedString` in native UI.

### Storage layout

```
~/.maho/                   # global config (macOS)
├── config.yaml            # auth, embed model, sync.cloud
├── vaults.yaml            # registry when cloud sync OFF
├── vaults-cache.yaml      # offline fallback of iCloud registry
└── vaults/                # device + github vault storage

~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents/
├── config/vaults.yaml     # registry when cloud sync ON
└── vaults/                # iCloud vault storage

<vault>/
├── maho.yaml              # the ONLY config file per vault (decision #13)
├── .maho/                 # gitignored: index.db, device config, sync-manifest.json
└── <collection>/
    ├── _index.md          # ordering + collection metadata
    └── *.md               # notes
```

## Conventions that aren't obvious from the code

- **`mn skill`** prints the canonical AI-agent usage guide. When in doubt about CLI behavior, run `swift run mn skill` rather than guessing — it documents guardrails, frontmatter rules, and JSON shapes. When a command's flags, JSON shape or error codes change, update the guide text in `Sources/mn/Commands/SkillCommand.swift` in the same change.
- **Frontmatter is written through `FrontmatterDocument` / `YAMLFormat`** (`Sources/MahoNotesKit/FrontmatterDocument.swift`), never by interpolating a value into a `key: value` line. A bare title such as `Plan: Q4` is invalid YAML, and a writer that rebuilds the file as `"---\n…\n---\(body)"` drops the line break after the closing delimiter — both used to corrupt notes and `_index.md` files. Note-level operations for the CLI (create with body, body write/append/edit, metadata, delete, path resolution) live in `Sources/MahoNotesKit/NoteWriting.swift` and throw `NoteError`, whose `code` is the `error.code` of `--json` output.
- **CLI errors** are thrown as `CLIError` or `NoteError`, not printed and followed by `ExitCode.failure`. `MahoNotes.report(_:)` prints them as JSON on stdout when `--json` was given and as text on stderr otherwise.
- **Tests**: `Tests/MahoNotesKitTests` covers the library; `Tests/mnTests` runs the built `mn` binary end to end, each invocation with a temp `CFFIXED_USER_HOME` and an explicit `--vault <temp dir>`.
- **All CLI commands support `--json` and `--vault <name>`** via `OutputOption` / `VaultOption` (see `Sources/mn/`). Wire these into new commands the same way.
- **Design decisions are numbered** in `docs/decisions.md` (#1–#28+). When changing something with cross-cutting implications (sync, search, embedding model, UI zones), check the decision log before diverging — many choices have non-obvious tradeoffs documented there (e.g., #21 NLEmbedding removal, #24 BGE-M3 → e5-large, #28 NTHU Purple theme zones).
- **Localizations**: `App/MahoNotes/Localizable.xcstrings` is the source of truth for `en`, `zh-Hant`, `ja`, `ko`, `fr`, `it`, `es`. New UI strings must be added there; the build sets `SWIFT_EMIT_LOC_STRINGS: YES`. `InfoPlist.xcstrings` covers Info.plist values.
- **Two GitHub sync paths must stay in agreement**: `GitSync.swift` (CLI, `git` binary subprocess, macOS-gated) and `GitHubSyncManager.swift` (REST API, all platforms including iOS). Conflict-file format (`note.conflict-{DeviceName}.md`), `sync-manifest.json` format, and ignored-paths logic must match across the two. What they share lives in `SyncConflicts.swift`: the `.gitignore` entries, conflict-copy detection, and `CollectionIndexMerge` (the three-way merge both use for a collection `_index.md` changed on both sides). Neither path may overwrite the remote without reconciling first — the REST path compares manifest / local / remote per file and pushes without force (decision #33). `Tests/MahoNotesKitTests/GitHubSyncManagerTests.swift` runs it against an in-memory GitHub (`FakeGitHub`); `GitSyncTests` uses a local bare repo.
- **The editor never replaces text while an input method is composing.** On macOS the composing (marked) text is in the `NSTextView` but not in the `editingBody` binding until it is committed, so writing the binding back during a view update wipes it. `MarkdownEditorView` skips that while `hasMarkedText()`, and `EditorState` tracks the on-disk body the buffer came from (`baseBody`) so a reload after sync updates a clean buffer and never a dirty one (`reconcileWithDisk()`, `diskChange(buffer:base:disk:)`).
- **Bundle ID is `dev.pcca.mahonotes`**, team `K867NAPA93`. iCloud container is `iCloud.dev.pcca.mahonotes`; app group is `group.dev.pcca.mahonotes`. One shared `MahoNotes.entitlements` for both platforms.
- **License is PolyForm Noncommercial 1.0** — not OSI-open. Keep this in mind for dependency additions and any code-sharing suggestions.
