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

The Xcode project (`App/MahoNotes.xcodeproj`) is gitignored — always run `xcodegen generate` after pulling or after editing `App/project.yml`. CI is currently disabled (`.github/workflows/ci.yml.disabled`).

### Homebrew distribution

The CLI ships through a **separate tap repo** (`mahopan/tap`) — there is no formula in this repository. Releases of `mn` are built and tagged here, then the formula in the tap repo points at the tag's source tarball / binary.

```bash
brew tap mahopan/tap
brew install maho-notes              # formula name per App/MahoNotes/Resources/GettingStarted.bundle/getting-started/010-cli.md
```

Note: `README.md` currently shows `brew install mn` while the in-app tutorial shows `brew install maho-notes`. The tutorial bundle is the more recently-updated source; treat that name as canonical and fix the README if you touch this area. The CLI binary is always called `mn` regardless of formula name.

## Architecture

Three artifacts share one Swift codebase:

- **`MahoNotesKit`** (`Sources/MahoNotesKit/`) — library. All persistence, search, sync, markdown rendering, site generation. Both the CLI and the app depend on this. *Mostly* platform-agnostic, but several Kit files (`Auth.swift`, `GitSync.swift`, `VaultInit.swift`, `VaultRegistry.swift`, `VaultStore.swift`) use `#if os(macOS)` to gate things like `Process` invocations, `gh` lookup paths, and `~/.maho` resolution — iOS uses the app's Documents directory instead. Keep that pattern when adding code that touches the filesystem or subprocesses.
- **`mn`** (`Sources/mn/`) — CLI executable using `swift-argument-parser`. One file per subcommand under `Sources/mn/Commands/`. New subcommands are registered in `Sources/mn/MahoNotes.swift`. **Version strings live in four places and must be kept in sync when releasing**: `App/project.yml` (`MARKETING_VERSION`), `Sources/mn/MahoNotes.swift` (`CommandConfiguration.version`), `Sources/mn/Commands/SkillCommand.swift` (the `version` field in `--json` output), and `README.md`'s version badge.
- **`MahoNotes` app** (`App/MahoNotes/`) — SwiftUI universal app, single target building for macOS 15+ and iOS/iPadOS 18+. Depends on `MahoNotesKit` via the local Swift package.

### macOS / iPad / iPhone split inside the app

The app target is universal, but each form factor has its own root view and the codebase uses `#if os(macOS)` / `#if os(iOS)` heavily to keep them apart:

| Form factor | Root view | Distinctive files |
|-------------|-----------|------------------|
| macOS | `ContentView.swift` | `SettingsView.swift`, `MacAddVaultSheet.swift`, `FloatingToolbarView` (macOS branch) |
| iPad | `IPadContentView.swift` | `IPadVaultRail.swift`, `IPadAddVaultSheet.swift` — 3-column layout matching macOS (vault rail / navigator / content) |
| iPhone | `iPhoneContentView.swift` | slide-over vault rail, `NavigationStack` push, bottom toolbar |
| iOS-shared (iPad + iPhone) | `iOSSettingsView.swift` | iOS-only settings UI; macOS uses `SettingsView.swift` |
| cross-platform | `AppState.swift`, `NavigatorView.swift`, `NoteContentView.swift`, `MarkdownEditorView.swift`, `NoteRowContent.swift`, `CollectionRowContent.swift`, `NoteRowActions.swift` | shared between all three; conditional code inside |

When adding UI, prefer reusing the cross-platform views and gating only the bits that genuinely differ. iOS-only files start with `#if os(iOS)` at the top of the file — match that pattern instead of sprinkling per-view conditionals.

**Entitlements** are a single file (`App/MahoNotes/MahoNotes.entitlements`) used for both platforms. It enables iCloud (CloudDocuments, container `iCloud.dev.pcca.mahonotes`), the `group.dev.pcca.mahonotes` app group, app sandbox, network client, app-scope bookmarks, and user-selected read/write. The stale comment in `project.yml` mentioning `MahoNotes_macOS.entitlements` / `MahoNotes_iOS.entitlements` does not reflect the current layout — there's only the one file.

**Tip Jar (StoreKit 2)**: `TipJarManager.swift` + `TipJarView.swift` drive consumable IAPs (`com.mahonotes.tip.small/medium/large`) wired through `App/MahoNotes/Products.storekit` (referenced by `scheme.storeKitConfiguration` in `project.yml`). Shown inside both `SettingsView` (macOS) and `iOSSettingsView` (iOS).

**Getting Started bundle**: `App/MahoNotes/Resources/GettingStarted.bundle/getting-started/` is shipped as an app resource. `GettingStartedBundler.swift` materializes it into a real vault on first run as the tutorial vault.

### VaultStore is the persistence boundary

`VaultStore` (actor, `Sources/MahoNotesKit/VaultStore.swift`) is the single entry point for all YAML/JSON reads and writes that touch vault state — registry, global config, per-vault config, paths. Older free functions (`loadRegistry`, `saveRegistry`, `resolvedPath`, …) still exist; `VaultStore` currently wraps them and is the migration target. **New persistence code should go through `VaultStore`, not the free functions.** See `docs/vault-store.md` for the RFC and the bugs the actor design exists to fix (path divergence, write-only cache, no concurrency safety).

### Search has three modes and one index

- FTS5 keyword search via `swift-cjk-sqlite` (CJK tokenizer for 中英日韓 inside the same SQLite file).
- Semantic search via `swift-embeddings` (HuggingFace Safetensors models, MLTensor runtime). Vectors live in the same SQLite DB via `sqlite-vec`. Models: `minilm` (default, ~90MB) / `e5-small` / `e5-large` (~2.2GB).
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

- **`mn skill`** prints the canonical AI-agent usage guide. When in doubt about CLI behavior, run `swift run mn skill` rather than guessing — it documents guardrails, frontmatter rules, and JSON shapes.
- **All CLI commands support `--json` and `--vault <name>`** via `OutputOption` / `VaultOption` (see `Sources/mn/`). Wire these into new commands the same way.
- **Design decisions are numbered** in `docs/decisions.md` (#1–#28+). When changing something with cross-cutting implications (sync, search, embedding model, UI zones), check the decision log before diverging — many choices have non-obvious tradeoffs documented there (e.g., #21 NLEmbedding removal, #24 BGE-M3 → e5-large, #28 NTHU Purple theme zones).
- **Localizations**: `App/MahoNotes/Localizable.xcstrings` is the source of truth for `en`, `zh-Hant`, `ja`, `ko`, `fr`, `it`, `es`. New UI strings must be added there; the build sets `SWIFT_EMIT_LOC_STRINGS: YES`. `InfoPlist.xcstrings` covers Info.plist values.
- **Two GitHub sync paths must stay in agreement**: `GitSync.swift` (CLI, `git` binary subprocess, macOS-gated) and `GitHubSyncManager.swift` (REST API, all platforms including iOS). Conflict-file format (`note.conflict-{DeviceName}.md`), `sync-manifest.json` format, and ignored-paths logic must match across the two.
- **Bundle ID is `dev.pcca.mahonotes`**, team `K867NAPA93`. iCloud container is `iCloud.dev.pcca.mahonotes`; app group is `group.dev.pcca.mahonotes`. One shared `MahoNotes.entitlements` for both platforms.
- **License is PolyForm Noncommercial 1.0** — not OSI-open. Keep this in mind for dependency additions and any code-sharing suggestions.
