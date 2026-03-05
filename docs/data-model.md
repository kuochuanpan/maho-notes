# Data Model

## Note (Markdown File)

Each note is a markdown file with YAML frontmatter:

```markdown
---
title: 訓讀 vs 音讀
tags: [漢字, 読み方, N5]
created: 2026-03-03T09:18:00-05:00
updated: 2026-03-03T09:44:00-05:00
public: false
slug: kunyomi-vs-onyomi
author: maho
---

# 訓讀 vs 音讀

Content here...
```

> Collection is inferred from the file path: `japanese/grammar/001-kunyomi-onyomi.md` → collection: `japanese`

## Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | string | ✅ | Display title |
| `tags` | string[] | ❌ | Searchable tags |
| `created` | datetime | ✅ | Creation timestamp |
| `updated` | datetime | ✅ | Last modified |
| `public` | boolean | ❌ | If true, publishable as web page (default: false) |
| `slug` | string | ❌ | URL slug for published notes |
| `author` | string | ❌ | `maho` or `kuochuan` (default from `maho.yaml`) |
| `draft` | boolean | ❌ | Draft status (default: false) |
| `order` | number | ❌ | Sort order within collection |
| `series` | string | ❌ | Group notes into a series (e.g., "日語基礎") |

> **Note:** Collection is determined by the note's directory path, not by a frontmatter field. A note at `japanese/grammar/001-xxx.md` belongs to the `japanese` collection. This avoids redundancy and prevents path/metadata inconsistency.

## Configuration

Four layers of config, from most specific to most global:

```
Layer 1: Per-vault config (synced)
  <vault>/maho.yaml             # Vault identity + collections + optional github/site

Layer 2: Per-vault device config (local only)
  <vault>/.maho/config.yaml     # Device-specific vault settings (gitignored)

Layer 3: Global device config (local only)
  ~/.maho/config.yaml           # Auth tokens, default embed model, device preferences

Layer 4: Vault registry (synced via iCloud)
  iCloud~com.pcca.mahonotes/config/vaults.yaml  # Which vaults exist, types, access
```

### Layer 1: maho.yaml (per vault, synced)

`maho.yaml` is the **single config file per vault**. Its presence identifies a directory as a Maho Notes vault.

```yaml
# maho.yaml — single source of truth per vault
title: "Kuo-Chuan's Notes"
author:
  name: Kuo-Chuan Pan
  url: https://pcca.dev
collections:
  - id: japanese
    name: 日本語
    icon: character.book.closed
    description: 日語學習筆記
  - id: astronomy
    name: 天文筆記
    icon: sparkles
    description: 天文物理研究筆記
  - id: simulation
    name: 模擬日誌
    icon: terminal
    description: 數值模擬運行紀錄與分析
github:
  repo: kuochuanpan/maho-vault         # optional, only if synced to GitHub
site:
  domain: notes.pcca.dev
  title: Kuo-Chuan's Notes
  theme: default
```

**Field reference:**
- `title`: vault display name
- `author`: default author info for new notes (`mn new` auto-fills frontmatter)
- `collections`: content organization — add/rename/reorder as needed
- `github`: vault repo for sync + publishing (optional)
- `site`: published site settings (optional)

> **Why one file?** `collections.yaml` was originally separate to reduce merge conflict risk. In practice, having two config files creates UX confusion and cognitive overhead. One file per vault = one source of truth = cleaner. See [Design Decision #13](decisions.md#13-single-config-file-per-vault).

### Layer 2: .maho/config.yaml (per vault, device-level, gitignored)

Per-vault settings that differ between devices. Lives inside the vault but is never synced.

```yaml
# Reserved for future per-vault device settings
# Examples: local cache preferences, vault-specific display options
# NOT for auth tokens (Layer 3) or embedding model (Layer 3 — must be global for cross-vault search)
```

> **Note:** Embedding model is NOT per-vault — it's global (Layer 3). Cross-vault vector search requires consistent dimensions across all vaults on the same device. Auth tokens also belong in Layer 3, never in a vault directory.

### Layer 3: ~/.maho/config.yaml (global, device-level)

Shared across all vaults on this device. Not synced anywhere.

```yaml
auth:
  github_token: ghp_xxx   # GitHub auth (from $GITHUB_TOKEN or gh auth)
embed:
  model: bge-m3            # embedding model for this device (applies to ALL vaults)
```

- Auth tokens live here, **never** in a vault (would leak to GitHub/iCloud)
- Embedding model is per-device, not per-vault — cross-vault search needs consistent vector dimensions
- On iOS/iPadOS: auth tokens stored in Keychain, preferences in UserDefaults

### Layer 4: vaults.yaml (vault registry, synced via iCloud)

Lives in the iCloud container so it syncs across all Apple devices automatically. See [Sync Strategy](sync-strategy.md#vault-registry) for full details.

```yaml
# iCloud~com.pcca.mahonotes/config/vaults.yaml
primary: personal
vaults:
  - name: personal
    type: icloud
    github: kuochuanpan/maho-vault
    access: read-write
  - name: cheatsheets
    type: github
    github: detailyang/awesome-cheatsheet
    access: read-only
```

CLI also maintains a local cache at `~/.maho/vaults-cache.yaml` for offline access.

> **Note on `github` field format:** In `maho.yaml` (Layer 1), `github` is a nested object (`github: { repo: "owner/repo" }`) to allow future sub-fields (e.g., branch, auto-sync settings). In `vaults.yaml` (Layer 4), `github` is a flat string (`github: owner/repo`) since the registry only needs the repo identifier. The vault registry is the canonical source for which vaults exist; `maho.yaml` is the canonical source for vault-level config.

### Config Precedence

When a setting exists at multiple layers, the most specific wins:

```
maho.yaml (Layer 1)  >  Per-vault .maho/config.yaml (Layer 2)  >  Global ~/.maho/config.yaml (Layer 3)  >  Defaults
```

Exceptions:
- `embed.model` is **global only** (Layer 3) — cross-vault search requires all vaults on the same device to share the same embedding model and vector dimensions
- Auth tokens are **global only** (Layer 3) — never stored in vault directories (would leak to GitHub/iCloud)

For CLI config commands, see [CLI Reference](cli.md#config--auth).

## Directory Structure

### Multi-Vault Layout (iCloud container)

```
iCloud~com.pcca.mahonotes/           # iCloud container (synced across Apple devices)
├── config/
│   └── vaults.yaml                  # Vault registry (which vaults exist)
└── vaults/
    ├── personal/                    # iCloud vault (read-write)
    │   ├── maho.yaml
    │   ├── japanese/
    │   ├── astronomy/
    │   └── .maho/                   # Per-vault local metadata (gitignored)
    ├── work/                        # iCloud vault (read-write)
    │   ├── maho.yaml
    │   └── meetings/
    └── journal/                     # iCloud vault (read-write)
        ├── maho.yaml
        └── 2026/

~/.maho/                             # Global device config (NOT synced)
├── config.yaml                      # Auth tokens, global defaults
├── vaults-cache.yaml                # Offline copy of vault registry
└── vaults/                          # GitHub-cloned vaults
    ├── cheatsheets/                 # GitHub vault (read-only)
    │   ├── maho.yaml
    │   └── ...
    └── rust-guide/                  # GitHub vault (read-only)
        ├── maho.yaml
        └── ...
```

### Single Vault Layout

Each vault has the same internal structure, regardless of type (iCloud / GitHub / local):

```
<vault>/
├── maho.yaml                  # Vault config + collections (synced)
├── japanese/                  # Collection: 日本語
│   ├── _index.md              # Collection overview (optional at any directory level)
│   ├── vocabulary/
│   │   ├── 001-star.md
│   │   └── 002-universe.md
│   ├── grammar/
│   │   ├── 001-kunyomi-onyomi.md
│   │   ├── 002-long-vowels.md
│   │   └── 003-small-kana.md
│   └── conversation/
│       └── 001-shopping.md
├── astronomy/                 # Collection: 天文
│   ├── _index.md
│   └── ...
├── simulation/                # Collection: 模擬日誌
│   └── ...
├── software/                  # Collection: 軟體開發
│   └── ...
├── _assets/                   # Shared images/attachments (referenced via relative paths)
│   └── ...
└── .maho/                     # Per-vault local metadata (gitignored, NOT synced)
    ├── config.yaml            # Device-level config for this vault (reserved for future use)
    ├── index.db               # SQLite: metadata + FTS5 + vector embeddings
    ├── publish-manifest.json  # Content hashes for incremental publishing
    └── cache/                 # Rendered HTML cache
```

## Nested Directories (Unlimited Depth)

Collections support **unlimited nesting**. The filesystem hierarchy IS the organization:

```
japanese/                  ← collection (top-level = defined in maho.yaml)
  grammar/                 ← subdirectory (any depth)
    basics/                ← deeper nesting is fine
      001-particles.md
    advanced/
      001-keigo.md
  vocabulary/
    001-star.md
```

- Top-level directories are collections (must be listed in `maho.yaml`)
- Subdirectories within a collection are free-form — create whatever hierarchy makes sense
- `_index.md` can appear at any level as a directory overview page
- App UI renders the tree structure; CLI uses path-based navigation

## Collections (in maho.yaml)

Collections are **entirely user-defined** via the `collections` section in `maho.yaml`. The app ships with no hardcoded collections. On first `mn init`, a getting-started tutorial is added as a **separate read-only vault** (cloned from `kuochuanpan/maho-getting-started`), keeping the user's primary vault clean. Users can remove it anytime with `mn vault remove getting-started`. Beyond that, users create their own collections via the app UI or by editing `maho.yaml` directly.

Icons use SF Symbols names (rendered via `Image(systemName:)` in SwiftUI). See the `maho.yaml` example above for the `collections` field format.
