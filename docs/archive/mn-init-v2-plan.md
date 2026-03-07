# mn init v2 — Redesign Plan

## Problems with v1
1. `mn init --vault <path>` conflates "vault root" with "a vault"
2. First-time user doesn't know where to put vaults
3. `--github` only writes to maho.yaml, doesn't clone content
4. No detection of existing setup (re-running mn init is confusing)
5. No iCloud vs local choice

## Design: Two Modes

### Mode 1: First-Time Setup (no `~/.maho/config.yaml` exists)

```
🔭 Welcome to Maho Notes!

Where would you like to store your vaults?
  1. iCloud (syncs across Apple devices)
     → ~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/vaults/
  2. Local (this machine only)
     → ~/.maho/vaults/
Choice [1/2]: _
```

> If iCloud container doesn't exist (Linux, no iCloud), skip choice → auto-select local.

```
Author name: Kuo-Chuan Pan

Do you have an existing vault on GitHub? (e.g., user/vault)
GitHub repo (leave blank to create new): kuochuanpan/maho-vault
```

**If GitHub repo provided:**
1. Clone repo into `<vault-root>/<repo-name>/` (e.g., `~/.maho/vaults/maho-vault/`)
2. Auto-detect: has `maho.yaml`? → native vault. No → import mode (generate maho.yaml)
3. Register in vault registry as primary
4. Name = repo name (without owner), e.g., `maho-vault`

**If no GitHub repo (blank):**
1. Ask vault name (default: `personal`)
2. Create empty vault at `<vault-root>/<name>/`
3. Clone getting-started tutorial
4. Register as primary

```
Vault name [personal]: _
```

**After setup:**
```
✅ Setup complete!

  Vault: maho-vault (primary)
  Path:  ~/.maho/vaults/maho-vault/
  Notes: 42

💡 Tip: Add this to your shell config (~/.zshrc):
   export PATH="$PATH:/path/to/mn"

Run `mn list` to see your notes.
Run `mn vault add <name> --github <repo>` to add more vaults.
```

### Mode 2: Already Configured (`~/.maho/config.yaml` exists)

```
🔭 Maho Notes is already set up on this machine.

Current vaults:
  * maho-vault (primary) — ~/.maho/vaults/maho-vault/
    cheatsheets (read-only) — ~/.maho/vaults/cheatsheets/

What would you like to do?
  1. Add a new vault
  2. Reconfigure (reset global config)
  3. Cancel
Choice [1/2/3]: _
```

Option 1 → same flow as "create vault" (name, GitHub or empty)
Option 2 → backup old config, re-run first-time wizard
Option 3 → exit

### Non-Interactive Mode

```bash
# First-time setup: create local vault
mn init --name personal --author "Name" --non-interactive

# First-time setup: clone GitHub vault
mn init --github kuochuanpan/maho-vault --author "Name" --non-interactive

# First-time setup: specify storage
mn init --storage icloud --github kuochuanpan/maho-vault --non-interactive
mn init --storage local --name personal --non-interactive

# Add vault to existing setup
mn init --name work --non-interactive
mn init --github org/work-notes --non-interactive
```

### Flag Changes

| Old Flag | New Flag | Behavior |
|----------|----------|----------|
| `--vault <path>` | removed from init | Use `--storage` + `--name` |
| `--github <repo>` | `--github <repo>` | Clone repo (not just config) |
| `--author <name>` | `--author <name>` | Same |
| `--no-tutorial` | `--no-tutorial` | Same |
| `--non-interactive` | `--non-interactive` | Same |
| (new) | `--storage <icloud\|local>` | Where to store vaults |
| (new) | `--name <name>` | Vault name (default: repo name or "personal") |

### Storage Resolution

```swift
func resolveVaultRoot(storage: Storage?) -> String {
    switch storage {
    case .icloud:
        return "~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/vaults/"
    case .local:
        return "~/.maho/vaults/"
    case nil:
        // Auto-detect: iCloud container exists? → iCloud, otherwise local
        if iCloudContainerExists() { return iCloud path }
        else { return local path }
    }
}
```

### Files Created/Modified

**First-time setup creates:**
- `~/.maho/config.yaml` (global device config — always in ~/.maho/)
- `<vault-root>/<name>/maho.yaml` (vault config)
- `<vault-root>/<name>/.maho/` (local vault data)
- `<vault-root>/<name>/.gitignore`
- `~/.maho/vaults.yaml` or iCloud `config/vaults.yaml` (registry)

### Edge Cases
- iCloud container path doesn't exist → suggest local, explain iCloud needs the app
- `mn init` run twice → Mode 2 (already configured)
- GitHub clone fails (network) → warn, offer to continue without, can `mn vault add` later
- Existing vault at target path → detect, ask to register (don't overwrite)

### Implementation Steps
1. Add `StorageOption` enum to MahoNotesKit
2. Add `resolveVaultRoot()` function
3. Rewrite `InitCommand.swift` with Mode 1/2 detection
4. Rewrite `VaultInit.swift` to support clone-as-init
5. Update tests (InitCommandTests)
6. Update docs (cli.md already correct, just verify)
