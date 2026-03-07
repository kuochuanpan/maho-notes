# Maho Notes — Design Overview

> A multilingual personal knowledge base with markdown rendering, cross-platform native apps, on-device vector search, and selective publishing.

## Architecture

```
┌───────────────────────────┐  ┌──────────┐
│   Universal App (SwiftUI)  │  │   CLI    │
│  macOS + iPadOS + iOS      │  │  (mn)    │
└──────────┬────────────────┘  └────┬─────┘
           │                        │
     ┌─────▼────────────────────────▼──────┐
     │           MahoNotesKit              │
     │                                     │
     │  ┌─────────────────────────────┐    │
     │  │  VaultStore (actor)         │    │ ← single entry point
     │  │  Registry, Config, Paths    │    │   for all persistence
     │  └─────────────────────────────┘    │
     │                                     │
     │  Vault · Note · Collection          │
     │  SearchIndex · VectorIndex          │
     │  GitSync · GitHubSyncManager        │
     │  SiteGenerator · Auth               │
     └──┬────────┬──────────┬──────┬───────┘
        │        │          │      │
   ┌────▼────┐ ┌─▼──────┐ ┌▼─────┐│
   │swift-cjk│ │swift-  │ │swift-││
   │-sqlite  │ │embedd- │ │github││
   │FTS5+CJK │ │ings    │ │-api  ││
   │+vec     │ │MLTensor│ │      ││
   └─────────┘ └────────┘ └──────┘│
```

### Key Principles

- **Markdown-first**: Notes are `.md` files with YAML frontmatter. No proprietary format.
- **Multilingual**: FTS5 + vector search across 中英日韓 via `swift-cjk-sqlite`.
- **Offline-first**: Everything works without network. Sync is additive.
- **Single source of truth**: `VaultStore` actor owns all config/registry persistence. See [vault-store.md](vault-store.md).

## Storage Layout

```
~/.maho/                          # Global config dir
├── config.yaml                   # Global: auth, embed model, sync.cloud
├── vaults.yaml                   # Vault registry (cloud sync OFF)
├── vaults-cache.yaml             # Offline cache of iCloud registry
└── vaults/                       # Device + GitHub vault storage
    ├── my-vault/
    └── some-repo/

~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents/
├── config/
│   └── vaults.yaml               # Vault registry (cloud sync ON)
└── vaults/                       # iCloud vault storage
    └── my-vault/

<vault>/                          # Any vault directory
├── maho.yaml                     # Vault config: author, collections, github, site
├── .maho/
│   ├── config.yaml               # Device-local: embed model override, auth token
│   └── sync-manifest.json        # REST API sync state (GitHubSyncManager)
├── .gitignore                    # Always includes .maho/
├── <collection>/
│   ├── _index.md                 # Collection metadata + ordering
│   └── *.md                      # Notes
└── getting-started/              # Optional tutorial collection
```

## Vault Types

| Type | Storage | Sync | Created by |
|------|---------|------|------------|
| `.icloud` | iCloud container | iCloud automatic | App (cloud sync ON) |
| `.device` | `~/.maho/vaults/` | None (local only) | App (cloud sync OFF), CLI |
| `.github` | `~/.maho/vaults/` | GitHub (git CLI or REST API) | `mn vault add --github`, App import |
| `.local` | User-specified path | None | `mn vault add --path` |

## Sync Strategy

- **iCloud**: Automatic via `NSMetadataQuery` monitoring. Conflict resolution via `NSFileVersion`.
- **GitHub (CLI)**: `mn sync` — uses `git` CLI (clone/pull/push). macOS only.
- **GitHub (App)**: `GitHubSyncManager` — REST API via `swift-github-api`. Works on all Apple platforms.
- **SyncCoordinator**: Auto-sync for GitHub vaults in the app — debounce 30s push + 5min periodic pull.
- **Conflict**: Device-name based conflict files (`note.conflict-{DeviceName}.md`).

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Shared logic | MahoNotesKit (Swift Package) |
| Native app | SwiftUI (macOS + iPadOS + iOS) |
| CLI | Swift (`mn`) via ArgumentParser |
| Database | `swift-cjk-sqlite` v0.2.0 (SQLite 3.48 + FTS5 + CJK + sqlite-vec) |
| Embeddings | `swift-embeddings` (MiniLM / E5-Small / E5-Large) |
| GitHub API | `swift-github-api` v0.2.0 (Device Flow OAuth + Git Data API) |
| Auth | Device Flow OAuth (App) / `gh auth` + env (CLI) |
| Publishing | Static HTML → GitHub Pages (`notes.pcca.dev`) |

## Repositories

| Repo | Purpose |
|------|---------|
| `kuochuanpan/maho-notes` | App + CLI + MahoNotesKit (public) |
| `kuochuanpan/maho-vault` | Personal vault (private) |
| `kuochuanpan/maho-getting-started` | Tutorial vault (public) |
| `mahopan/swift-cjk-sqlite` | FTS5 CJK tokenizer (public) |
| `mahopan/swift-github-api` | GitHub API client (public) |

## Documentation

| Doc | Contents |
|-----|----------|
| [VaultStore Design](vault-store.md) | Unified data access layer (RFC) |
| [Design Decisions](decisions.md) | Decision log (#1–#28) |
| `archive/` | Historical design docs (outdated but preserved) |

---

*Design by 真帆 🔭 — 2026-03-04, updated 2026-03-07*
