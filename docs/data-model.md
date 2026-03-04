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

Two layers of config: **vault-level** (shared across devices) and **device-level** (local only).

```
maho-vault/
  maho.yaml              # Vault-level config (synced with vault) — the ONE config file per vault
  .maho/
    config.yaml           # Device-level config (gitignored)
```

### maho.yaml (vault-level, synced — single source of truth per vault)

`maho.yaml` is the **only** config file per vault. It contains vault metadata, author info, collections, and optional GitHub/site settings. Its presence identifies a directory as a Maho Notes vault.

```yaml
# maho.yaml — the single config file per vault
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

### .maho/config.yaml (device-level, gitignored)

```yaml
embed:
  model: bge-m3           # per-device embedding model choice
```

- Embedding model is per-device (iPhone → Light, Mac → Pro)
- Auth tokens stored in `~/.maho/config.yaml` (global, device-level — not in vault)

For CLI config commands, see [CLI Reference](cli.md#config--auth).

## Directory Structure (maho-vault)

```
maho-vault/
├── maho.yaml                  # Vault config + collections — the ONE config file (synced)
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
└── .maho/                     # Local-only metadata (gitignored, NOT synced)
    ├── config.yaml            # Device-level config (embed model, etc.)
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
