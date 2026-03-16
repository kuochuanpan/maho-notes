import ArgumentParser

struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Print an AI-agent-friendly usage guide for mn"
    )

    @Flag(name: .long, help: "Output in JSON format")
    var json = false

    func run() {
        if json {
            printJSON()
        } else {
            print(skillText)
        }
    }

    private func printJSON() {
        // Escape for JSON
        let escaped = skillText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        print("""
        {"name":"maho-notes","version":"0.7.0","skill":"\(escaped)"}
        """)
    }
}

// MARK: - Skill Text

private let skillText = """
# Maho Notes (`mn`) — AI Agent Guide

> Personal knowledge base CLI with multi-vault support, full-text + semantic search,
> GitHub sync, and static site publishing. Designed for both humans and AI agents.

## Quick Start

```bash
mn init                              # first-time setup — creates or clones a vault
mn vault list                        # list registered vaults
mn new "Title" --collection notes    # create a note
mn list                              # list all notes
mn search "query"                    # full-text search
mn sync                              # sync with GitHub
```

## Multi-Vault Architecture

Vaults are registered in a central registry. Each vault is independent with its own
config (`maho.yaml`), collections (`collections.yaml`), and search index (`.maho/index.db`).

```bash
mn vault list                         # list all registered vaults
mn vault add --github user/repo       # add vault from GitHub (SSH-first, HTTPS fallback)
mn vault add --icloud                 # create vault in iCloud container
mn vault add --device                 # create local vault
mn vault add --path /some/local/dir   # register existing local directory
mn vault remove <name>                # unregister vault
mn vault set-primary <name>           # set default vault
mn vault info <name>                  # show vault details
```

Most commands accept `--vault <name>` to target a specific vault, or `--all` for all vaults.

## Commands

### Create

```bash
mn new "Title" --collection japanese --tags "N5, 漢字"
mn new "Title" --collection japanese/grammar    # nested collection path
```

### Read

```bash
mn list                              # all notes, grouped by collection
mn list --collection japanese        # filter by collection
mn list --tag N5                     # filter by tag
mn list --list-collections           # show available collections
mn list --list-tags                  # show all tags + counts
mn list --list-series                # show all series
mn show <path>                       # full note with metadata header
mn show <path> --body-only           # body only (for piping)
mn collections                       # collections overview with note counts
mn stats                             # vault statistics
```

### Search

```bash
# Keyword (FTS5 with CJK tokenizer — Chinese, Japanese, Korean supported)
mn search "query"                    # full-text keyword search (auto-builds index)
mn search "query" --json             # JSON output
mn search "query" --all              # search across all registered vaults

# Semantic (vector embeddings — requires `mn index --model <name>` first)
mn search "query" --semantic         # semantic vector search
mn search "query" --hybrid           # keyword + semantic with RRF fusion (k=60)
mn search "query" --hybrid --limit 20
```

| Mode | Flag | How it works | Best for |
|------|------|-------------|----------|
| Keyword | (default) | FTS5 BM25 | Exact terms, code, hashes |
| Semantic | `--semantic` | Vector cosine similarity | Meaning-based, cross-lingual |
| Hybrid | `--hybrid` | Keyword + Semantic → RRF merge | Best of both worlds |

### Index

```bash
mn index                             # incremental FTS5 index update (mtime-based)
mn index --full                      # full FTS5 rebuild
mn index --model minilm              # build vector index with embedding model
mn index --model e5-small            # multilingual-e5-small (better for CJK)
mn index --model minilm --full       # full vector rebuild
mn index --all                       # index all registered vaults
```

### Metadata

```bash
mn meta <path>                       # show frontmatter
mn meta <path> --set title="New"     # update field
mn meta <path> --set public=true     # mark as publishable (shows warning)
mn meta <path> --add-tag "grammar"
mn meta <path> --remove-tag "draft"
```

### Config

```bash
mn config                            # show vault + device config
mn config set author.name "Name"     # vault-level (maho.yaml)
mn config set github.repo "user/repo"
mn config set site.title "My Notes"
mn config set embed.model minilm
```

### Sync (GitHub)

```bash
mn sync                              # git pull + push (primary vault)
mn sync --vault <name>               # sync specific vault
mn sync --all                        # sync all vaults with GitHub configured
mn sync --reindex                    # rebuild search index after sync
```

### Publish (Static Site)

```bash
mn publish                           # generate static site from public notes
mn publish <path>                    # mark note public + publish
mn publish --preview                 # generate to temp dir and open in browser
mn publish --force                   # full rebuild ignoring manifest
mn unpublish <path>                  # mark note private + remove from site
```

### Embedding Models

```bash
mn model list                        # show available models + download status
mn model download <name>             # pre-download a model
mn model remove <name>               # delete cached model files
```

| Alias | Dimensions | Size | Best for |
|-------|-----------|------|----------|
| `minilm` | 384 | ~80MB | Quick setup, iPhone |
| `e5-small` | 384 | ~120MB | Multilingual, iPad |
| `e5-large` | 1024 | ~2.2GB | Best quality, Mac |

### Other

```bash
mn open <path>                       # open in $EDITOR
mn delete <path>                     # delete note (moves to trash)
```

## Guardrails — When to Use `mn` vs Direct File Edit

| Operation | Use `mn` | Direct edit | Why |
|-----------|----------|------------|-----|
| Create note | ✅ `mn new` | ❌ | Auto-generates frontmatter, numbering, slug |
| Read note | Either | ✅ | `mn show` or `cat` — both fine |
| Edit body | ❌ | ✅ | Just edit the .md file directly |
| Modify metadata | ✅ `mn meta` | ❌ | Validates keys, prevents bad overwrites |
| Add/remove tags | ✅ `mn meta` | ❌ | Preserves array format |
| Set config | ✅ `mn config set` | ❌ | Validates keys and values |
| Delete note | ✅ `mn delete` | Acceptable | `mn delete` adds safety (trash) |
| Search | ✅ `mn search` | ❌ | FTS5 ranking, CJK support |

## Frontmatter Rules (Important!)

- **Never** add `collection:` to frontmatter — it is inferred from the file path
- **Never** set tags via `--set tags=x` — use `--add-tag` / `--remove-tag`
- **Never** edit frontmatter YAML by hand — use `mn meta`
- `created` and `updated` are auto-managed — don't touch them

Valid `--set` fields: `title`, `public`, `slug`, `author`, `draft`, `order`, `series`

## Config Keys

Valid for `mn config set`:
`author.name`, `author.url`, `github.repo`, `site.domain`, `site.title`, `site.theme`, `embed.model`

Section keys (`author`, `github`, `site`) cannot be set directly — use dotted paths.

## JSON Output

All commands support `--json` for structured output:
```bash
mn list --json
mn show <path> --json
mn search "query" --json
mn collections --json
mn stats --json
mn index --json
mn sync --json
```

## Vault Structure

```
vault-dir/
├── maho.yaml            # vault config
├── collections.yaml     # collection definitions
├── japanese/            # collection directory
│   ├── _index.md        # collection overview (optional)
│   ├── _assets/         # images and attachments for this collection
│   ├── vocabulary/      # nested sub-collection
│   └── grammar/
├── astronomy/
├── _assets/             # vault-level shared assets
├── .maho/               # local only (gitignored)
│   └── index.db         # FTS5 + vector search index
└── .gitignore           # auto-managed
```

## Asset Handling

- Images and files live in `_assets/` directories (per-collection or vault-level)
- Assets sync with GitHub (not excluded from git)
- Image syntax: `![alt|alignment|width](_assets/file.png)`
  - alignment: `left`, `center`, `right`
  - width: `25`-`100` (percent)
"""
