import ArgumentParser
import Foundation

struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Print an AI-agent-friendly usage guide for mn"
    )

    @Flag(name: .long, help: "Output in JSON format")
    var json = false

    func run() throws {
        if json {
            try printJSONDict(["name": "maho-notes", "version": mnVersion, "skill": skillText])
        } else {
            print(skillText)
        }
    }
}

// MARK: - Skill Text

private let skillText = #"""
# Maho Notes (`mn`) — AI Agent Guide

> Personal knowledge base CLI: Markdown notes in vaults, full-text + semantic search,
> GitHub / iCloud sync, static-site publishing. Every command that reads or changes notes
> takes `--json`.

## Writing notes — the short version

```bash
# 1. See which collections exist
mn list --list-collections --json

# 2. Create the note with its body in one call (the result has its path)
mn new "Title" --collection notes --tags "a, b" --stdin --json <<'EOF'
Body in Markdown. A "# Title" heading is added above it for you.
EOF

# 3. Later: add to it, change part of it, change its metadata
mn write notes/title.md --append --body "- one more line"
mn edit  notes/title.md --find "old text" --replace "new text"
mn meta  notes/title.md --add-tag done --set title="New title"
```

Rules that keep notes intact:

- **Create with `mn new`**, never by writing a file yourself — it builds valid frontmatter,
  picks the filename, and registers the note in the collection's order.
- **Change frontmatter with `mn meta`**, never by hand. It rewrites only the fields you
  name and refuses a change that would leave the frontmatter unreadable.
- **Change the body with `mn write` / `mn edit`.** They never touch frontmatter except to
  bump `updated`. Editing the `.md` file directly is also fine (path: `absolutePath` in
  any `--json` result) as long as you leave the frontmatter block alone.
- **Multi-line text goes through `--stdin` (heredoc) or `--file`**, not `--body`: the shell
  does not turn `\n` inside quotes into a line break, and `mn` does not either.
- Never add `collection:` to frontmatter (it is the note's folder — use `mn move`), and
  never set `created` / `updated` (managed for you).

## Paths and vaults

- A note path is relative to the vault: `notes/my-note.md`. The `.md` is optional, and an
  absolute path inside the vault also works. Paths that leave the vault are rejected.
- A wrong path fails with `note_not_found` and lists the closest existing notes under
  `suggestions` — retry with one of those.
- Commands act on the primary vault. Choose another with `--vault <name or folder path>`
  or the `MN_VAULT` environment variable. `mn vault list --json` shows what is registered.

## Create

```bash
mn new "Title" --collection japanese --tags "N5, 漢字"
mn new "Title" --collection japanese/grammar            # nested collection
mn new "Title" --collection notes --body "One-line body"
mn new "Title" --collection notes --file draft.md       # body from a file
mn new "Title" --collection inbox --create-collection   # collection that doesn't exist yet
mn new "Title" --collection notes --if-exists skip      # safe to retry: reuses the existing note
```

- The collection must already exist, so a typo cannot start a new one. Pass
  `--create-collection` when you do want a new collection.
- `--if-exists`: `suffix` (default — creates `title-1.md`), `error`, or `skip` (returns the
  existing note with `"action": "exists"`). Use `skip` or `error` when a retry must not
  leave duplicates.
- An empty body from `--stdin` / `--file` is refused by `mn write` (`missing_body`), so a
  failed pipe cannot blank a note; `--body ""` clears a body on purpose.
- `--no-heading` adds no `# Title` heading (and no stub body when no body is given). `--author` defaults to `author.name` in
  the vault config. `--series <name>` sets the series.
- JSON result: `{"action": "created", "path", "absolutePath", "note": {…metadata…}}`.

## Read

```bash
mn list --json                         # every note's metadata (no bodies)
mn list --collection japanese/grammar  # one collection (nested paths work)
mn list --tag N5 --series "Kanji"      # filter by tag / series
mn list --sort updated --limit 10      # most recently changed; also: created, title
mn list --json --body                  # include bodies (large — prefer `mn show`)
mn list --all                          # every registered vault
mn list --list-collections | --list-tags | --list-series
mn show <path> --json                  # one note: metadata + body + absolutePath
mn show <path> --body-only             # body only, for piping
mn meta <path> --json                  # metadata only
mn collections --json                  # collections with note counts
mn stats --json                        # vault statistics
```

## Change

```bash
mn write <path> --stdin < new-body.md          # replace the whole body
mn write <path> --append --body "- 14:00 deployed"
mn edit  <path> --find "exact text" --replace "new text"   # must match exactly once
mn edit  <path> --find "TODO" --replace "DONE" --all        # every occurrence
mn meta  <path> --set title="New" --set public=true --unset series
mn meta  <path> --add-tag grammar --remove-tag draft
mn move  <path> --to archive                   # another collection; assets move with it
mn delete <path>                               # to the Trash; --force removes it outright
```

- `mn write --append` starts a new paragraph, except that a list item appended to a list
  (or a table row to a table) continues it on the next line.
- `mn edit` matches exactly and case-sensitively, in the body only. `text_not_found` and
  `ambiguous_text` (several matches without `--all`) leave the note untouched.
- `mn meta --set` fields: `title`, `author`, `series`, `slug` (text), `public`, `draft`
  (`true` / `false`), `order` (whole number). Tags only via `--add-tag` / `--remove-tag`.
- Setting `public=true` makes the note part of the published site on the next `mn publish`.

## Search

```bash
mn search "query" --json               # keyword search (FTS5, CJK-aware), best 10
mn search "query" --limit 30
mn search "query" --vault work         # one vault (default: all registered vaults)
mn search "query" --semantic           # meaning-based; needs `mn index --model <name>` first
mn search "query" --hybrid             # keyword + semantic, fused with RRF
```

Keyword search updates its index before every query, so a note you just wrote is
found straight away. The vector index used by `--semantic` / `--hybrid` is only updated
by `mn index`.

| Mode | Flag | Best for |
|------|------|----------|
| Keyword | (default) | Exact terms, names, code |
| Semantic | `--semantic` | Meaning, cross-lingual queries |
| Hybrid | `--hybrid` | Both |

```bash
mn index                               # update the keyword index (and the vector index if a model is set)
mn index --full                        # rebuild from scratch
mn index --model minilm                # build the vector index: minilm, e5-small, e5-large
mn index --all                         # every registered vault
mn model list | download <name> | remove <name>
```

## JSON output and errors

- `--json` output is one JSON document on stdout. Note objects use the keys
  `relativePath`, `title`, `collection`, `tags`, `created`, `updated`, `isPublic`,
  `draft`, and when set `author`, `series`, `slug`, `order`; `mn show` adds `body` and
  `absolutePath`.
- Commands that change a note return `{"action", "path", "absolutePath", "note"}`, with
  `action` one of `created`, `exists`, `replaced`, `appended`, `edited`, `updated`,
  `moved`, `trashed`, `deleted`.
- A failure exits non-zero (1, or 64 when the arguments themselves are invalid). With
  `--json` it prints `{"error": {"code", "message", "hint", "suggestions"}}` on stdout;
  without, a message on stderr. Codes: `note_not_found`, `note_exists`,
  `collection_not_found`, `invalid_collection`, `invalid_path`, `empty_title`,
  `invalid_frontmatter`, `unreadable_note`, `unknown_field`, `managed_field`,
  `invalid_value`, `text_not_found`, `ambiguous_text`, `missing_body`, `invalid_input`,
  `already_there`, `vault_not_found`, `vault_read_only`, `sync_failed`,
  `invalid_arguments`; anything else is `error`.

## Vaults

```bash
mn init                               # first-time setup — creates or clones a vault
mn vault list                         # registered vaults
mn vault add <name> --github user/repo      # clone a GitHub vault (SSH first, HTTPS fallback)
mn vault add <name> --icloud | --device     # new vault in iCloud / on this device
mn vault add <name> --path /some/local/dir  # register an existing folder
mn vault remove <name>                # unregister (files stay unless --delete)
mn vault set-primary <name>           # default vault for commands
mn vault info <name>
mn vault find                         # vaults, collections and notes on disk that don't show up
mn vault find --fix                   # add / repair them (never deletes files)
```

`mn vault find` reports vault folders missing from the registry, collection folders missing
from `maho.yaml` (or listed without a folder), and notes the app can't show: notes at the
vault root (moved to `unsorted/` by `--fix`), `.markdown` / `.MD` files (renamed to `.md`),
UTF-16/32 files (converted to UTF-8), and notes iCloud hasn't downloaded. Run it read-only
first; a vault added by `--fix` is only checked on the next run.

## Sync, publish, config

```bash
mn sync                               # git pull + push for the vault (GitHub vaults)
mn sync --all                         # every vault with GitHub configured; prints one result per
                                      # vault and exits non-zero if any of them failed
mn sync --reindex                     # rebuild the search index afterwards
mn publish                            # build the static site from public notes, commit and push
mn publish <path>                     # mark one note public and publish
mn publish --preview                  # build to a temp folder and open it
mn unpublish <path>                   # mark private and remove from the site
mn config                             # show vault + device config
mn config set author.name "Name"      # keys: author.name, author.url, github.repo,
                                      #       site.domain, site.title, site.theme, embed.model
mn open <path>                        # open in $EDITOR
```

`mn sync` and `mn publish` push to GitHub — run them when the user asks for it, not as a
side effect of writing a note.

## Vault layout

```
vault/
├── maho.yaml            # the vault's only config file: title, author, collections, site
├── japanese/            # a collection is a folder
│   ├── _index.md        # ordering (order: notes, children: sub-collections) + description
│   ├── _assets/         # images and attachments for this collection
│   ├── grammar/         # nested collection
│   └── kanji-basics.md  # a note: YAML frontmatter + Markdown body
├── _assets/             # vault-wide assets
└── .maho/               # device-local, not synced: index.db, sync-manifest.json
```

- Note order comes from `_index.md`, not from filenames — don't add numeric prefixes.
- Images: `![alt|alignment|width](_assets/file.png)` — alignment `left` / `center` /
  `right`, width `25`–`100` (percent).
- Ruby annotations: `{漢字|かんじ}` renders the reading above the base text.
"""#
