# Maho Notes

[![Version](https://img.shields.io/badge/version-1.0.3-blue)](https://github.com/kuochuanpan/maho-notes/releases)
[![License](https://img.shields.io/badge/license-PolyForm%20NC%201.0-green)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20iOS%20%7C%20iPadOS-lightgrey?logo=apple)](https://github.com/kuochuanpan/maho-notes)
[![App Store](https://img.shields.io/badge/App%20Store-available-blue?logo=apple)](https://apps.apple.com/us/app/maho-notes/id6760572212)

A personal knowledge base for humans and AI agents.

**Multi-platform native app** (macOS + iPadOS + iOS) with a powerful **CLI** (`mn`) — built in Swift.

**[📲 Download on the App Store](https://apps.apple.com/us/app/maho-notes/id6760572212)** — available for macOS, iOS, and iPadOS.

## Features

- **Multi-vault** — organize notes across local, iCloud, and GitHub-synced vaults
- **Full-text search** — FTS5 with CJK tokenizer (中文、日本語、한국어)
- **Semantic search** — on-device vector embeddings (MiniLM, E5-small, E5-large)
- **Hybrid search** — reciprocal rank fusion combining keyword + semantic results
- **GitHub sync** — git-based sync with conflict resolution (device-name split)
- **iCloud sync** — seamless cross-device sync via CloudDocuments
- **Markdown editor** — formatting toolbar with 14 actions, ⌘K search, KaTeX math, ruby annotations `{漢字|ふりがな}`
- **Static publishing** — generate a site from public notes (CLI only; app integration planned)
- **AI-agent friendly** — `mn skill` outputs a comprehensive usage guide; all commands support `--json`

## Install

### App (macOS / iOS / iPadOS)

Get it from the [App Store](https://apps.apple.com/us/app/maho-notes/id6760572212) — one universal app for Mac, iPhone, and iPad.

### CLI via Homebrew

```bash
brew tap mahopan/tap
brew install mn
```

### Build from source

```bash
# CLI
git clone https://github.com/kuochuanpan/maho-notes.git
cd maho-notes
swift build -c release
# Binary at .build/release/mn

# App
cd App
xcodegen generate
open MahoNotes.xcodeproj
```

## Quick Start

```bash
mn init                              # set up your first vault
mn new "Hello World" --collection notes --body "My first note."
mn write notes/hello-world.md --append --body "- one more thought"
mn list
mn search "hello"
mn sync                              # sync with GitHub
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `mn init` | Set up Maho Notes or add a new vault |
| `mn new` | Create a new note, optionally with its body (`--body`, `--stdin`, `--file`) |
| `mn write` | Replace a note's body, or append to it |
| `mn edit` | Replace exact text in a note's body |
| `mn move` | Move a note to another collection |
| `mn list` | List notes grouped by collection (`--sort`, `--limit`, filters) |
| `mn show` | Display a note with metadata |
| `mn search` | Full-text, semantic, or hybrid search |
| `mn meta` | Show or modify note frontmatter |
| `mn open` | Open a note in your editor |
| `mn delete` | Delete a note (moves to trash) |
| `mn config` | Show or set configuration |
| `mn collections` | List collections with note counts |
| `mn stats` | Show vault statistics |
| `mn index` | Build or rebuild search index |
| `mn sync` | Sync vault with GitHub |
| `mn vault` | Manage vaults (list, add, remove, set-primary, info, find) |
| `mn model` | Manage embedding models |
| `mn publish` | Publish public notes as a static site |
| `mn unpublish` | Mark a note as private |
| `mn skill` | Print AI-agent usage guide |

All commands support `--json` for structured output and `--vault <name>` to target a specific vault.

## For AI Agents

```bash
mn skill           # comprehensive usage guide (markdown)
mn skill --json    # machine-readable format
```

The `mn skill` command outputs everything an AI agent needs to use the CLI correctly — commands, guardrails, frontmatter rules, search modes, and vault structure.

An agent can write a complete note in one call and get back where it landed:

```bash
mn new "Meeting notes" --collection work --tags "meeting, q4" --stdin --json <<'EOF'
## Decisions
- Ship on Friday
EOF
# {"action": "created", "path": "work/meeting-notes.md", "absolutePath": "…", "note": {…}}

mn edit work/meeting-notes.md --find "Friday" --replace "Monday"
mn meta work/meeting-notes.md --add-tag decided
```

- **Notes stay valid.** Titles and tags with YAML syntax in them (`Plan: Q4`, `c#`) are quoted, `mn meta` rewrites only the fields it is asked to change, and body commands never touch frontmatter.
- **Mistakes are caught, not written.** A mistyped collection is an error instead of a new collection, paths cannot leave the vault, and `--if-exists skip` makes a retried `mn new` reuse the note instead of duplicating it.
- **Errors are data.** With `--json`, a failure prints `{"error": {"code", "message", "hint", "suggestions"}}` and exits non-zero; a wrong note path comes back with the closest existing paths.
- **Small output.** `mn list --json` returns metadata without bodies, `mn search` returns the best 10 by default, and keyword search always sees notes written a moment ago.

## Search

```bash
mn search "query"                    # keyword (FTS5 + CJK)
mn search "query" --semantic         # vector similarity
mn search "query" --hybrid           # keyword + semantic (RRF fusion)
```

Vector search requires building an index first:

```bash
mn index --model minilm              # ~80MB, fast
mn index --model e5-small            # ~120MB, multilingual
mn index --model e5-large            # ~2.2GB, best quality
```

## Vault Structure

```
vault/
├── maho.yaml              # vault config (incl. collection definitions)
├── notes/                 # collection directory
│   ├── _index.md          # collection overview
│   ├── _assets/           # images and attachments
│   └── my-note.md         # a note
├── .maho/                 # local only (gitignored)
│   └── index.db           # search index
└── .gitignore
```

## Tech Stack

- **Language**: Swift 6.0
- **Platforms**: macOS 15+, iOS 18+, iPadOS 18+
- **UI**: SwiftUI (NavigationSplitView, adaptive layouts)
- **Search**: [swift-cjk-sqlite](https://github.com/mahopan/swift-cjk-sqlite) (FTS5 + CJK + sqlite-vec)
- **Embeddings**: [swift-embeddings](https://github.com/jkrukowski/swift-embeddings) (MLTensor)
- **GitHub API**: [swift-github-api](https://github.com/mahopan/swift-github-api) (Device Flow OAuth)
- **Markdown**: [swift-markdown](https://github.com/swiftlang/swift-markdown)

## License

[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/) — free for personal and noncommercial use.
