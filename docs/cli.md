# CLI Reference (`mn`)

The CLI is a first-class interface — not just for humans, but for AI agents.
It must support full CRUD, search, and publishing with scriptable (JSON) output.

```bash
# ── Init (Onboarding Wizard) ──────────────────────
mn init                               # interactive first-run setup: ~/.maho/ + first vault
mn init --no-tutorial                 # skip tutorial vault clone
# First-time: creates global config (~/.maho/), sets up vault registry, guides user through:
#   1. Where to store notes? (iCloud / Local / GitHub)
#   2. Optional GitHub sync? (repo URL)
#   3. Author info?
# Creates: maho.yaml + .maho/ + .gitignore in chosen vault path
# Also: auto-adds getting-started tutorial as read-only vault (cloned from kuochuanpan/maho-getting-started)
# Offline: tutorial vault skipped gracefully, user can add later via mn vault add
# Idempotent: safe to run again (only adds missing config, never overwrites)
# Universal app reuses the same init logic for first-launch setup

# ── Create & Delete ───────────────────────────────
mn new "Title" --collection japanese --tags "N5,漢字"  # creates in japanese/ dir, auto-generates frontmatter
mn new "Title" --collection japanese/grammar --tags "N5"  # nested: creates in japanese/grammar/
mn delete <path>                      # move to trash / confirm

# ── Read ──────────────────────────────────────────
mn show <path>                        # display note with metadata
mn show <path> --body-only            # body content only (no frontmatter, for piping)
mn list                               # all notes in primary vault, grouped by collection
mn list --vault <name>                # list notes in specific vault
mn list --all                         # list notes across all vaults
mn list --collection japanese         # filter by collection
mn list --tag N5                      # filter by tag
mn list --series                      # list all series across vault
mn list --series "日語基礎"            # filter notes in that series

# ── Edit ──────────────────────────────────────────
mn open <path>                        # open in $EDITOR (human use, macOS/Linux)
# AI agents: edit markdown files directly (don't touch frontmatter block)

# ── Metadata ──────────────────────────────────────
mn meta <path>                        # show frontmatter
mn meta <path> --set public=true      # update frontmatter field
mn meta <path> --add-tag "grammar"    # add tag
mn meta <path> --remove-tag "draft"   # remove tag

# ── Search ────────────────────────────────────────
mn search "長音規則"                    # full-text search across all vaults (FTS5)
mn search --vault personal "長音規則"   # search within specific vault
mn search --semantic "how do vowels work"  # vector search
mn search --collection japanese "query"    # scoped search
mn search --semantic "query" --limit 5     # top-K results

# ── Publishing ────────────────────────────────────
mn publish                            # incremental: only regenerate + push changed notes
mn publish --force                    # full rebuild (e.g., after theme change)
mn publish <path>                     # set public:true + generate + push (one-step)
mn unpublish <path>                   # set public:false + remove from published site
mn publish --preview                  # local preview before push
# Workflow: mn meta --set public=true (mark only) → mn publish (deploy later)
# Or just: mn publish <path> (marks + deploys in one step)
# Publishing is incremental by default — uses content hashes to detect changes.

# ── Vault Management (Phase 1d) ───────────────────
mn vault list                         # list all registered vaults (name, type, access, sync status)
mn vault add <name> --icloud          # create new iCloud vault (stored in iCloud container)
mn vault add <name> --github <repo>   # add GitHub-backed vault (auto clone)
mn vault add <name> --github <repo> --readonly  # add as read-only (pull only, no push)
mn vault add <name> --github <repo> --import    # add non-Maho repo (auto-generate maho.yaml from structure)
mn vault add <name> --path <local>    # register existing local directory as vault (macOS only)
mn vault remove <name>                # unregister vault (does NOT delete files)
mn vault remove <name> --delete       # unregister + delete local files
mn vault set-primary <name>           # change default vault
mn vault info <name>                  # show vault details (type, path, remote, access, last sync, note count)

# ── Sync & Index ──────────────────────────────────
mn sync                               # sync primary vault
mn sync --vault <name>                # sync specific vault
mn sync --all                         # sync all vaults
mn sync --reindex                     # sync + rebuild index
# First run: if vault is empty + github.repo configured → auto clone from repo
# Read-only vaults: pull only, never push
mn index                              # rebuild SQLite FTS index (+ embeddings if model configured)
mn index --model bge-m3               # specify embedding model
mn index --vault <name>               # index specific vault
mn index --all                        # index all vaults

# ── Config & Auth ─────────────────────────────────
mn config                             # show all config (vault + device + global)
mn config set <key> <value>           # set vault-level config (maho.yaml)
mn config set author.name "Name"      # vault-level: default author for new notes
mn config set site.domain "notes.example.com"  # vault-level: published site domain
mn config set --device <key> <value>             # per-vault device config (.maho/config.yaml)
mn config set --global embed.model bge-m3        # global: embedding model (applies to ALL vaults on this device)
mn config auth                        # GitHub auth (stored in ~/.maho/config.yaml — global, not per-vault)
mn config auth --status               # check auth status (token source, validity)

# ── Info ──────────────────────────────────────────
mn collections                        # list collections + series within each
mn stats                              # note/word count, per-collection and per-series breakdown
```

## AI Agent Workflow

**Rule: metadata via CLI, body content is free.**

| Operation | Method | Why |
|-----------|--------|-----|
| Create note | `mn new` | Auto-generates valid frontmatter (no `collection` field — inferred from path) |
| Modify metadata | `mn meta` | Validates fields, prevents accidental `public: true` |
| Delete / Publish | `mn delete` / `mn publish` | Safety confirmation |
| Read content | Direct file read or `mn show` | No risk, either is fine |
| Write / edit body | Direct file edit | Fine as long as frontmatter block (`---`) is untouched |
| Search | `mn search` | FTS5 / vector index |

```bash
# All commands support --json for scripting:
mn list --json
mn search "query" --json
```

## Global Flags

| Flag | Description |
|------|-------------|
| `--vault <name>` | Target vault by name (default: primary vault) |
| `--json` | Machine-readable JSON output (for AI agents / scripts) |
| `--quiet` | Suppress non-essential output |
| `--verbose` | Debug output |

## Vault Location Resolution

| Priority | Source | Path |
|----------|--------|------|
| 1 | `--vault <name>` flag | Explicit vault by registered name |
| 2 | `$MN_VAULT` env var | Vault name or path |
| 3 | Primary vault | As set in vault registry |
| 4 | Legacy auto-detect | iCloud container → `~/maho-vault` fallback |

The vault registry (in iCloud container `config/vaults.yaml`) is the source of truth for vault registrations. On first use (no registry exists), the CLI auto-detects iCloud container on macOS and creates a default registry entry. CLI also maintains a local cache of the registry at `~/.maho/vaults-cache.yaml` for offline access.

For full vault registry details, see [Sync Strategy](sync-strategy.md#vault-registry).
