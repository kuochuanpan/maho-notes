# Sync Strategy

## Two Sync Layers

The primary vault lives in iCloud by default. GitHub is an optional second layer for power users.

```
iCloud sync (automatic, transparent)
├── Handled by OS — app/CLI don't intervene
├── Same Apple ID devices sync automatically
└── Default vault location is iCloud container

mn sync (GitHub, explicit)
├── Cross-Apple-ID bridging (e.g., Maho ↔ Kuo-Chuan)
├── Version control (git history)
├── Publishing source
└── Requires: mn config auth + mn vault add <name> --github <repo>
```

`mn sync` syncs vaults with their configured GitHub remotes. iCloud settles first (local), then GitHub sync runs against the settled local state.

## Multi-Vault Architecture (Phase 1d)

A user can have **multiple vaults** — one primary (iCloud) and any number of additional GitHub-backed vaults. This enables:
- **Knowledge separation**: personal notes, work notes, reference material in distinct repos
- **Community content**: add public GitHub markdown repos (cheat sheets, awesome-lists, language guides) as read-only vaults
- **Sharing**: publish a vault as a public repo so others can add it to their own setup

```
┌─────────────────────────────────────────────────────────┐
│                      Maho Notes                         │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Primary Vault│  │ Work Vault   │  │ Cheat Sheets │  │
│  │ (iCloud+Git) │  │ (GitHub)     │  │ (read-only)  │  │
│  │ read-write   │  │ read-write   │  │ pull-only    │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                 │                 │           │
│         └────────┬────────┴────────┬────────┘           │
│                  │                 │                     │
│            ┌─────▼─────┐   ┌──────▼──────┐              │
│            │Cross-vault │   │ Per-vault   │              │
│            │  Search    │   │  FTS index  │              │
│            └───────────┘   └─────────────┘              │
└─────────────────────────────────────────────────────────┘
```

## Vault Types

| Type | Source | Access | Sync |
|------|--------|--------|------|
| **Primary** | iCloud (+ optional GitHub) | read-write | iCloud auto + `mn sync` |
| **GitHub (owned)** | Your GitHub repo | read-write | `mn sync` (pull + push) |
| **GitHub (public/read-only)** | Others' public repos | read-only (local changes stay local) | `mn sync` (pull only, never push) |

## Vault Registry

The vault registry lives in the **iCloud container** so it syncs across all Apple devices automatically:

```
iCloud~com.pcca.mahonotes/
├── config/
│   └── vaults.yaml          # Vault registry (synced to all devices)
└── vaults/
    ├── personal/             # iCloud vault 1
    │   ├── maho.yaml
    │   └── japanese/
    ├── work/                 # iCloud vault 2
    │   ├── maho.yaml
    │   └── meetings/
    └── journal/              # iCloud vault 3
        ├── maho.yaml
        └── 2026/
```

Registry uses **type-based resolution** instead of absolute paths (paths differ per platform):

```yaml
# iCloud~com.pcca.mahonotes/config/vaults.yaml
primary: personal                  # default vault for mn new, mn list, etc.
vaults:
  - name: personal
    type: icloud                   # path resolved per-platform at runtime
    github: kuochuanpan/maho-vault # optional GitHub remote for backup/sync
    access: read-write
  - name: work
    type: icloud
    access: read-write
  - name: journal
    type: icloud
    access: read-write
  - name: cheatsheets
    type: github
    github: detailyang/awesome-cheatsheet
    access: read-only
  - name: rust-guide
    type: github
    github: nicenemo/master-rust
    access: read-only
  - name: local-notes
    type: local
    path: ~/Documents/my-notes     # only for type:local — macOS CLI only
    access: read-write
```

## Vault Type Path Resolution

Each platform resolves vault paths at runtime based on `type`:

| Type | macOS CLI | macOS App | iOS/iPadOS |
|------|-----------|-----------|------------|
| `icloud` | `~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/vaults/<name>/` | Same | App's iCloud container |
| `github` | `~/.maho/vaults/<name>/` | App Support | App container |
| `local` | User-specified path | Same | ❌ Not supported |

- **iCloud vaults** can be created freely (multiple!) — each is a subdirectory in the iCloud container
- **GitHub vaults** are cloned to platform-appropriate local storage
- **Local vaults** are macOS-only (for existing Obsidian/Zettelkasten dirs, etc.)

See [Design Decision #14](decisions.md#14-vault-registry-in-icloud) for rationale.

## Device-Level Config (NOT synced)

Auth tokens and device-specific settings are stored **per-device**, never in iCloud:

| Platform | Location | Contents |
|----------|----------|----------|
| macOS CLI | `~/.maho/config.yaml` | Auth tokens, embed model, cache |
| macOS/iOS App | Keychain + UserDefaults | Auth tokens (Keychain), preferences (UserDefaults) |

The `~/.maho/` directory on macOS CLI also serves as cache for GitHub vault clones.

## Read-Only Vault Behavior

- `mn sync` → pull only, never push
- `mn new`, `mn delete`, `mn meta --set` → blocked with clear error: "This vault is read-only"
- Local file edits are allowed (user's filesystem) but won't sync back
- `mn sync` will overwrite local changes with upstream (reset to remote)
- Search works normally (indexed like any vault)

## Multi-Backend Storage

App must work standalone (App Store requirement). iCloud is default; GitHub is optional.

| Backend | Use Case | Platforms |
|---------|----------|-----------|
| **Local only** | Default, App Store friendly | macOS, iPadOS, iOS |
| **iCloud** | Seamless Apple device sync, zero config | macOS, iPadOS, iOS |
| **GitHub** | Cross-Apple-ID sync, version control, collaboration, publishing | All |

## Sync Modes

### Mode 1: iCloud Only (Default)
For most users. Zero config, just works.
```
iPhone ←──iCloud──→ iPad ←──iCloud──→ Mac
         (same Apple ID)
```

### Mode 2: iCloud + GitHub (Power User / Cross-Apple-ID)
Enable GitHub sync in Settings. GitHub acts as a bridge between different Apple IDs or between human and AI agent.

```
Apple ID A                   GitHub                Apple ID B
┌──────────┐   auto sync    ┌────────┐  auto sync  ┌──────────┐
│ Device A │ ←────────────→ │  repo  │ ←─────────→ │ Device B │
│ (iCloud A)│               │        │              │ (iCloud B)│
└──────────┘               └────────┘   iCloud     └─────┬────┘
                                         sync       ┌────▼────┐
                                                     │Device B2│
                                                     │(iCloud B)│
                                                     └─────────┘
```

Real-world example (our setup):
- Maho (Mac mini, Apple ID A) → writes notes via CLI → auto push to GitHub
- GitHub repo → auto pull to Kuo-Chuan's MacBook (Apple ID B)
- MacBook iCloud → syncs to Kuo-Chuan's iPhone/iPad

### GitHub Sync Behavior (When Enabled)
- **Auto push**: On note save, debounced (e.g., 30s after last edit)
- **Auto pull**: On app launch + periodic (e.g., every 5 min) + pull-to-refresh
- **What syncs**: Markdown files + `maho.yaml` + `_assets/`
- **What doesn't sync**: `.maho/` (local DB, embeddings, cache, auth tokens)

## Conflict Resolution

**Conflict handling (simple: split + manual resolve):**
1. Detect: on sync, compare `updated` timestamp + content hash
2. If both sides changed same file → keep both versions:
   - `note.md` ← newer version
   - `note.conflict-{timestamp}-{source}.md` ← older version
3. App shows ⚠️ badge on conflicted notes
4. User opens both files → compares manually → keeps preferred version
5. Resolving deletes the `.conflict-*` file

**Layer-specific details:**
- iCloud layer: hook into `NSFileVersion` to detect iCloud-level conflicts
- GitHub layer: detect diverged commits on pull
- **Rejected push (non-fast-forward)**: pull first → if conflict, split into two versions → then push. Never force push.
- **iCloud ↔ GitHub ordering**: iCloud settles first (local), then GitHub sync runs against the settled local state. GitHub sync is debounced (30s) to avoid racing with iCloud.
- **No auto-merge** — markdown content is hard to merge safely
- **No lock mechanism** — too complex, doesn't work offline

## New Device Setup

**CLI (new Mac):**
```bash
mn config auth                   # GitHub auth (device-level, no vault needed)
mn init                          # interactive: set up primary vault (iCloud or GitHub)
# Vault registry syncs via iCloud — existing vaults appear automatically
# GitHub vaults need: mn sync --all (clone remotes)
```

**App (new iPhone/iPad):** Sign in with same Apple ID → iCloud vaults appear automatically. GitHub vaults: Settings → Sync → pull.

## Offline Support

- Full local storage → always works offline
- iCloud: automatic background sync when online
- GitHub: queues changes, syncs when online
