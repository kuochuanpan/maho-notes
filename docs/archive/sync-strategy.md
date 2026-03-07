# Sync Strategy

## Sync Architecture

The sync layer is designed around an abstract **`SyncProvider`** protocol. iCloud is the first (and initially only) cloud sync implementation. The abstraction preserves room for future backends (Google Drive, Synology Drive, WebDAV, Dropbox, etc.) without redesigning the sync pipeline. GitHub is a separate, optional layer — not a general sync backend, but a version control + publishing bridge.

## Cloud Sync Setting

A per-device setting controls whether Maho Notes uses iCloud for vault storage and registry sync.

| Setting | Value | Effect |
|---------|-------|--------|
| `sync.cloud` | `icloud` (default) | Vault registry + iCloud vaults stored in iCloud container; syncs across all Apple devices with same Apple ID |
| `sync.cloud` | `off` | Vault registry stored locally; `type: icloud` vaults cannot be created; only `device`, `github`, `local` vault types available |

**Storage location:**

| Platform | Cloud Sync ON | Cloud Sync OFF |
|----------|--------------|----------------|
| macOS CLI | `~/.maho/config.yaml` → `sync: { cloud: icloud }` | `~/.maho/config.yaml` → `sync: { cloud: off }` |
| macOS/iOS App | `UserDefaults` (per-device — NOT stored in iCloud to avoid chicken-and-egg) | Same |

**vaults.yaml location:**

| Cloud Sync | vaults.yaml path | Notes |
|------------|-----------------|-------|
| ON (icloud) | `iCloud~com.pcca.mahonotes/config/vaults.yaml` | Syncs across all Apple devices (current design) |
| OFF | macOS: `~/.maho/vaults.yaml` / iOS: App Documents `config/vaults.yaml` | Local only, no cross-device sync |

CLI also maintains a local cache at `~/.maho/vaults-cache.yaml` for offline access (regardless of cloud sync setting).

### Switching Cloud Sync

**OFF → ON:**
1. Migrate `~/.maho/vaults.yaml` → iCloud container `config/vaults.yaml`
2. Offer to convert `device` vaults → `icloud` (copy files to iCloud container, update `type`)
3. User can also keep `device` vaults alongside new `icloud` vaults

**ON → OFF:**
1. Copy `vaults.yaml` from iCloud container → local path
2. `icloud` vaults must be downgraded to `device` (copy files from iCloud container to app-managed local path, update `type`)
3. ⚠️ **Destructive**: UI must warn "Other devices will no longer sync these vaults"
4. `github` field preserved on all vaults (sync behavior unchanged)

## Two Sync Layers

The primary vault lives in iCloud by default (when Cloud Sync is ON). GitHub is an optional second layer for power users.

```
iCloud sync (automatic, transparent) — requires Cloud Sync ON
├── Handled by OS — app/CLI don't intervene
├── Same Apple ID devices sync automatically
└── Default vault location is iCloud container

mn sync (GitHub, explicit) — works regardless of Cloud Sync setting
├── Cross-Apple-ID bridging (e.g., Maho ↔ Kuo-Chuan)
├── Version control (git history)
├── Publishing source
└── Requires: mn config auth + mn vault add <name> --github <repo>
```

`mn sync` syncs vaults with their configured GitHub remotes. For iCloud vaults, iCloud settles first (local), then GitHub sync runs against the settled local state.

## Multi-Vault Architecture

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
│  │ (iCloud+Git) │  │ (iCloud)     │  │ (read-only)  │  │
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

> **"Primary" = "Default"**: The primary vault is simply whichever vault is set as the default (via `mn vault set-primary <name>`). It's the target for commands when no `--vault` flag is specified. Any vault can be primary — there's no special type, just a designation in the vault registry.

| Type | Source | Access | Sync | Requires Cloud Sync |
|------|--------|--------|------|---------------------|
| **iCloud** | iCloud container | read-write | iCloud auto + optional `mn sync` (GitHub) | ✅ Yes |
| **Device** | App-managed local path | read-write | None (optional `mn sync` for GitHub) | ❌ No |
| **GitHub (owned)** | Your GitHub repo | read-write | `mn sync` (pull + push) | ❌ No |
| **GitHub (read-only)** | Others' public repos | read-only (local changes stay local) | `mn sync` (pull only, never push) | ❌ No |
| **Local** | Local directory (macOS only) | read-write | None (manual backup) | ❌ No |

### `device` vs `local` vs `icloud`

| | `icloud` | `device` | `local` |
|---|---|---|---|
| Path decided by | OS (iCloud container) | App (platform-appropriate) | User (arbitrary path) |
| Platforms | All (macOS, iOS, iPadOS) | All (macOS, iOS, iPadOS) | macOS only |
| Cross-device sync | ✅ iCloud auto | ❌ (optional GitHub) | ❌ |
| Use case | Default for most users | No-iCloud users, iOS offline | Existing Obsidian/Zettelkasten dirs |
| Cloud Sync required | ✅ | ❌ | ❌ |

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
# vaults.yaml (location depends on Cloud Sync setting — see above)
primary: personal                  # default vault for mn new, mn list, etc.
vaults:
  - name: personal
    type: icloud                   # path resolved per-platform at runtime (Cloud Sync ON only)
    github: kuochuanpan/maho-vault # optional GitHub remote for backup/sync
    access: read-write
  - name: work
    type: icloud
    access: read-write
  - name: journal
    type: icloud
    access: read-write
  - name: offline-notes
    type: device                   # app-managed local storage (works with Cloud Sync ON or OFF)
    access: read-write
    github: user/offline-notes     # optional GitHub backup
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
| `device` | `~/.maho/vaults/<name>/` | App Support `vaults/<name>/` | App Documents `vaults/<name>/` |
| `github` | `~/.maho/vaults/<name>/` | App Support | App container |
| `local` | User-specified path | Same | ❌ Not supported |

- **iCloud vaults** can be created freely (multiple!) — each is a subdirectory in the iCloud container. Requires Cloud Sync ON.
- **Device vaults** are app-managed local storage — path is platform-appropriate, works on all platforms regardless of Cloud Sync setting. Default vault type when Cloud Sync is OFF.
- **GitHub vaults** are cloned to platform-appropriate local storage
- **Local vaults** are macOS-only (for existing Obsidian/Zettelkasten dirs, etc.)

> **Note on `device` vs `github` paths on macOS CLI:** Both resolve to `~/.maho/vaults/<name>/`. The difference is semantic: `github` vaults have a mandatory GitHub remote and are synced via `mn sync`; `device` vaults have no mandatory remote (GitHub is optional).

See [Design Decision #14](decisions.md#14-vault-registry-in-icloud) for rationale.

## Device-Level Config (NOT synced)

Auth tokens and device-specific settings are stored **per-device**, never in iCloud:

| Platform | Location | Contents |
|----------|----------|----------|
| macOS CLI | `~/.maho/config.yaml` | Auth tokens, embed model, cloud sync setting, cache |
| macOS App | Keychain + UserDefaults | Auth tokens (Keychain), preferences incl. cloud sync (UserDefaults) |
| iOS / iPadOS App | Keychain + UserDefaults | Auth tokens (Keychain), preferences incl. cloud sync (UserDefaults) |

The `~/.maho/` directory on macOS CLI also serves as storage for device vaults and GitHub vault clones.

## Read-Only Vault Behavior

- `mn sync` → pull only, never push
- `mn new`, `mn delete`, `mn meta --set`, `mn publish` → blocked with clear error: "Vault '<name>' is read-only"
- `mn sync` will overwrite local changes with upstream (reset to remote state)
- Local file edits are allowed (user's filesystem) but are not tracked or synced back — next `mn sync` will overwrite them
- Search works normally (indexed like any vault)

## Multi-Backend Storage

App must work standalone (App Store requirement). Device-local storage is always available; iCloud is opt-in (default ON); GitHub is optional.

| Backend | Use Case | Platforms | Requires Cloud Sync |
|---------|----------|-----------|---------------------|
| **Device only** | Offline-first, no cloud dependency | macOS, iPadOS, iOS | ❌ |
| **iCloud** | Seamless Apple device sync, zero config | macOS, iPadOS, iOS | ✅ |
| **GitHub** | Cross-Apple-ID sync, version control, collaboration, publishing | All | ❌ |

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

**App** (automatic):
- **Auto push**: On note save, debounced (e.g., 30s after last edit)
- **Auto pull**: On app launch + periodic (e.g., every 5 min) + pull-to-refresh

**CLI** (explicit):
- GitHub sync only runs when the user invokes `mn sync` — never automatic
- **What syncs**: Markdown files + `maho.yaml` + `_assets/`
- **What doesn't sync**: `.maho/` (local DB, embeddings, cache, auth tokens)

## Conflict Resolution

**Conflict handling (simple: remote-wins + split for manual resolve):**
1. Detect: on sync, compare `updated` timestamp + content hash
2. If both sides changed same file → keep both versions:
   - `note.md` ← remote version (always wins — consistent, predictable)
   - `note.conflict-{timestamp}-local.md` ← local version (preserved for manual review)
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
