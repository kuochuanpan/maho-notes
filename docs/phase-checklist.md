# Development Phase Checklist

## Phase 1a — CLI Core ✅ complete

Local CRUD fully functional. No network, no database.

- [x] Vault directory structure + collections (in maho.yaml)
- [x] CLI (`mn`): new, list, show, search (basic grep)
- [x] Initial Japanese notes populated (7 notes)
- [x] **Migration**: Remove `collection` field from existing note frontmatter (infer from path)
- [x] **Migration**: Update `maho.yaml` icons from emoji to SF Symbols
- [x] **Migration**: Update `Note` model + `Vault` — collection inferred from `relativePath`, not frontmatter
- [x] **Migration**: Remove `SyncCommand` from registered subcommands (sync is Phase 1c; keep source files for later)
- [x] **Migration**: Add `_index.md` to existing collection directories (japanese/, astronomy/, etc.)
- [x] CLI: `mn init` (create vault + `maho.yaml` + `.maho/`)
- [x] CLI: open, delete
- [x] CLI: meta (frontmatter manipulation — key whitelist, blocked keys, public=true warning)
- [x] CLI: config (vault-level `maho.yaml` + device-level `.maho/config.yaml` — key validation)
- [x] CLI: collections, stats (including series)
- [x] CLI: `--json` output for all commands (`Note` + `Collection` conform to `Codable`)
- [x] CLI: `mn show --body-only` (pipe-friendly body output)
- [x] CLI: `mn list --list-collections`, `--list-tags`, `--list-series` (discovery flags)
- [x] Nested directory support (unlimited depth within collections)
- [x] Vault location auto-detection (iCloud container on macOS, `~/maho-vault` fallback)
- [x] Friendly error when vault not found (actionable suggestions)
- [x] Collection auto-discovery from filesystem (undeclared dirs with .md files, 📁 default icon)
- [x] CLI emoji fallback for SF Symbols icons (JSON preserves raw SF Symbol names)
- [x] Unit tests: 42 tests in 8 suites (FrontmatterParser, makeSlug, nextFileNumber, Note, Collection, Vault CRUD, Config Validation, Collection Discovery)
- [x] GitHub Actions CI (swift build + swift test on macOS 15)
- [x] OpenClaw skill (`maho-notes`) for agent guardrails

## Phase 1b — Full-Text Search ✅ complete

### Design Decisions

**Index location**: `.maho/index.db` (gitignored, not synced via iCloud or Git — each device builds its own)

**Auto-index on search**: When `mn search` is invoked and no `index.db` exists, automatically build the index first and print a one-time notice (`Building search index...`). Users should never need to manually run `mn index` before their first search.

**Incremental indexing**: `mn index` compares each note's file mtime against the last-indexed timestamp stored in a `_meta` table. Only changed/new files are re-indexed; deleted files are pruned. `mn index --full` forces a complete rebuild. This is fast enough for Phase 1b (< 1000 notes); revisit if needed.

**FTS5 content strategy**: Copy content into the FTS5 table (not `content=` external content mode). Simpler to implement, trades ~2× storage for straightforward insert/delete. Phase 3 (vector search) can revisit if `index.db` size becomes a concern.

**Ranking weights**: Use FTS5 `bm25()` with column weights — title (10.0) > tags (5.0) > body (1.0). Results sorted by weighted BM25 score descending.

**Fallback**: If `index.db` is corrupted, missing, or schema version mismatches, fall back to the existing substring search (current `Vault.searchNotes`) and print a warning suggesting `mn index --full`. Never crash on index errors.

### Checklist

- [x] Integrate [`swift-cjk-sqlite`](https://github.com/mahopan/swift-cjk-sqlite) as SPM dependency (v0.1.0)
  - Bundles SQLite 3.48.0 with FTS5 + custom `cjk` tokenizer (Apple NLTokenizer for CJK segmentation)
  - Already has CI (macOS + iOS Simulator) + 19 regression tests
- [x] `SearchIndex` class in MahoNotesKit (FTS5 schema, index/query/prune methods)
  - Schema: `notes_fts(path, title, tags, body)` with tokenizer `cjk`
  - `_meta` table: `(path TEXT PRIMARY KEY, mtime REAL, indexed_at REAL)`
  - `_schema` table for version tracking (current: v1)
  - LIKE fallback for NLTokenizer segmentation edge cases ([swift-cjk-sqlite#1](https://github.com/mahopan/swift-cjk-sqlite/issues/1))
- [x] SQLite FTS5 index with `cjk` tokenizer for proper 中英日韓 full-text search
- [x] `mn search` upgrade: FTS5 `bm25()` ranking with column weights (title 10 / tags 5 / body 1)
  - Auto-build index on first search if `index.db` missing
  - Graceful fallback to substring search on index errors
- [x] `mn index` (build / rebuild FTS5 index from vault content)
  - Default: incremental (mtime-based diff)
  - `--full` flag: drop and rebuild from scratch
- [x] CLI and App share the same MahoNotesKit → same `swift-cjk-sqlite` → CJK search works everywhere

### Tests (Phase 1b) — 11 tests, all passing

- [x] Index build: create index from scratch, verify all notes indexed
- [x] Index rebuild (`--full`): drop + recreate, same results
- [x] Incremental update: modify one note, re-index, verify updated
- [x] Incremental delete: remove a note file, re-index, verify pruned from index
- [x] CJK search: query in 中文、日本語、한국어、English — all return correct results
- [x] Mixed-language note: single note with 中英日韓 content, all four languages searchable
- [x] Ranking order: title match ranks above body-only match
- [x] Empty vault: `mn index` + `mn search` on empty vault — no crash, sensible output
- [x] No match: search for nonexistent term — empty results, not an error
- [x] Fallback: corrupt/delete `index.db` — SearchIndex recovers (deletes and recreates)
- [x] Auto-index: `SearchIndex.indexExists()` detection for auto-build on first search

## Phase 1c — GitHub Sync ✅ complete

Basic GitHub sync working: `mn config auth`, `mn sync` (pull + push + first-run clone), `.gitignore`.

- [x] `mn config auth` — read `$GITHUB_TOKEN` env var → fallback `gh auth token` → store in `~/.maho/config.yaml`
- [x] `mn config auth --status` — show current auth state
- [x] Token stored device-level only (`~/.maho/config.yaml`), never synced to GitHub
- [x] Re-register `SyncCommand` in `MahoNotes.swift` subcommands
- [x] Normal sync: `git pull --rebase` → `git add -A` → `git commit` → `git push`
- [x] First-run auto clone: detect empty/non-git vault + `github.repo` configured → `git clone`
- [x] Existing vault, no remote: `git remote add origin` from `github.repo` config
- [x] Handle non-fast-forward push (pull + retry)
- [x] `.gitignore` with `.maho/` entry on `mn init`

## Phase 1d — Multi-Vault + Sync Hardening

> Combines multi-vault architecture with remaining sync hardening from Phase 1c.
> Includes migration from single-vault (1a–1c) to multi-vault architecture.

### Single-Vault → Multi-Vault Migration
- [ ] Detect existing single-vault setup (vault path + `maho.yaml` + optional `github.repo` in config)
- [ ] Auto-create vault registry with existing vault as primary (`type: icloud` or `type: local`)
- [ ] Migrate `github.repo` from `maho.yaml` / `.maho/config.yaml` → vault registry `github` field
- [ ] Migrate `collections.yaml` → merge into `maho.yaml` (see below)
- [ ] Migrate existing `.maho/index.db` → per-vault index (same location, just registry-aware)
- [ ] Migrate `getting-started/` embedded dir → read-only vault (optional, don't auto-delete old files)
- [ ] `VaultOption` → `VaultResolver`: backward compatible — if no registry, behave as single-vault
- [ ] `$MN_VAULT` env var accepts vault name (registered) or path (legacy)
- [ ] First `mn` invocation after update: detect old layout → run migration → print summary of changes

### Sync Hardening (from Phase 1c)
- [ ] `mn config auth --status` — show token source + masked value
- [ ] Auth: clear error when no token found (guide user to `$GITHUB_TOKEN` or `gh`)
- [ ] Auth: handle `gh` installed but not logged in → treat as absent, guide user
- [ ] Auth: token validation against GitHub API → clear error + prompt re-auth on 401/403
- [ ] Pre-flight: `git` not installed → friendly error with `xcode-select --install` guidance
- [ ] Pre-flight: iCloud container but iCloud Drive disabled → warn (non-blocking)
- [ ] `mn sync --reindex` — rebuild FTS index after sync
- [ ] Auth token injection: `GIT_ASKPASS` or URL-embed for HTTPS remote
- [ ] Post-clone vault validation (3-tier):
  - ✅ `maho.yaml` exists and parses → valid vault
  - ⚠️ No `maho.yaml` but has `.md` content files → warn + suggest `mn init`
  - ❌ No content `.md` files (only README/LICENSE) → error, refuse
- [ ] Conflict: detect rebase conflict → `git rebase --abort` → merge fallback
- [ ] Conflict: merge conflict → save local as `<note>.conflict-<timestamp>-local.md`, accept remote
- [ ] Conflict: non-fast-forward push → auto pull → retry push
- [ ] Conflict: print clear message listing conflicted files + `.conflict-*` paths
- [ ] `.gitignore`: verify `.maho/` entry on every `mn sync` (add if missing)

### Vault Registry
- [ ] Registry in iCloud container: `iCloud~com.pcca.mahonotes/config/vaults.yaml`
- [ ] Schema: `primary` (default vault name) + `vaults[]` (name, type, github, access)
- [ ] Type-based path resolution: `icloud` / `github` / `local` → platform-specific paths at runtime
- [ ] CLI local cache: `~/.maho/vaults-cache.yaml` (for offline access)
- [ ] Auto-create registry on first CLI use (detect existing vault → register as primary)

### `mn vault` Command
- [ ] `mn vault list` — show all vaults (name, type, access, last sync, note count)
- [ ] `mn vault add <name> --icloud` — create new iCloud vault (subdirectory in iCloud container)
- [ ] `mn vault add <name> --github <repo>` — clone repo, register as GitHub vault
- [ ] `mn vault add <name> --github <repo> --readonly` — read-only (pull only, no push)
- [ ] `mn vault add <name> --github <repo> --import` — non-Maho repo: auto-generate `maho.yaml` from directory structure
- [ ] `mn vault add <name> --path <local>` — register existing local directory (macOS only)
- [ ] `mn vault remove <name>` — unregister (keep files)
- [ ] `mn vault remove <name> --delete` — unregister + delete local files
- [ ] `mn vault set-primary <name>` — change default vault
- [ ] `mn vault info <name>` — vault details (type, path, remote, access, last sync, stats)
- [ ] Post-add vault validation (reuse Phase 1c 3-tier check)
- [ ] Block `mn vault add` if name already exists

### `mn init` (Onboarding Wizard)
- [ ] Creates global config (`~/.maho/`) + vault registry
- [ ] Interactive first-vault setup: iCloud (default) / Local / GitHub
- [ ] Prompts for author info, optional GitHub sync
- [ ] Non-interactive mode: `mn init --icloud` / `mn init --path <dir>` for scripting

### Merge `collections.yaml` into `maho.yaml`
- [ ] Move `collections` section into `maho.yaml` (single config file per vault)
- [ ] Remove `collections.yaml` loading from `Vault` / `Config`
- [ ] Migration: if `collections.yaml` exists, merge into `maho.yaml` and delete
- [ ] Update `mn init` to generate unified `maho.yaml` with collections section

### Multi-Vault Aware Commands
- [ ] `--vault <name>` flag on: `list`, `show`, `new`, `search`, `sync`, `index`, `stats`, `collections`
- [ ] `mn list --all` — list notes across all vaults (prefixed with vault name)
- [ ] `mn new` defaults to primary vault; `mn new --vault work` creates in work vault
- [ ] `mn sync` syncs primary; `mn sync --vault <name>` syncs one; `mn sync --all` syncs all
- [ ] `mn index --vault <name>` / `mn index --all`

### Read-Only Vault Enforcement
- [ ] `mn new`, `mn delete`, `mn meta --set` → error on read-only vault: "Vault '<name>' is read-only"
- [ ] `mn publish` on read-only vault → error: "Cannot publish from a read-only vault"
- [ ] `mn sync` on read-only vault → pull only, never push
- [ ] `mn sync` on read-only vault → overwrite local changes (reset to upstream)
- [ ] Local file edits allowed but not tracked/synced

### Cross-Vault Search
- [ ] Per-vault FTS index (`<vault>/.maho/index.db`)
- [ ] `mn search <query>` — search across all vaults by default
- [ ] `mn search --vault <name> <query>` — search within specific vault
- [ ] Results include vault name prefix: `[personal] japanese/grammar/001-...` vs `[cheatsheets] git/basics.md`
- [ ] `--collection` flag scoped within vault (or across all if no `--vault`)

### Tutorial as Read-Only Vault
- [ ] Create `kuochuanpan/maho-getting-started` public repo (tutorial markdown files)
- [ ] `mn init` auto-adds: `mn vault add getting-started --github kuochuanpan/maho-getting-started --readonly`
- [ ] `mn init --no-tutorial` skips tutorial vault
- [ ] Offline `mn init`: tutorial clone fails gracefully, prints guidance to add later
- [ ] Remove getting-started file generation from InitCommand (no longer embedded in primary vault)
- [ ] Migrate existing vaults: getting-started/ dir stays (no auto-delete), but new installs use vault

### VaultOption Migration
- [ ] Current `VaultOption` (single vault path resolution) → `VaultResolver` (multi-vault aware)
- [ ] Backward compatible: if no registry exists, behave like single-vault (auto-detect)
- [ ] `$MN_VAULT` env var accepts vault name (registered) or path (legacy)

### Missing Vault Path Handling
- [ ] Single-vault command (`mn list --vault work`) + path missing → friendly error with remediation steps:
  - Show missing path, suggest `mn vault update <name> --path <new>` or `mn vault remove <name>`
  - Mention external drive if path is under `/Volumes/`
- [ ] Cross-vault commands (`mn sync --all`, `mn search`) + some vaults missing → skip + warn per vault, continue others
  - Print `⚠️ Skipping vault '<name>': path not found (<path>)` for each missing vault
  - Never fail the entire command because one vault is unavailable
- [ ] `mn vault list` marks missing vaults: show status column (`ok` / `missing`)
- [ ] `mn vault add --path <path>` at registration time → verify path exists, error if not
- [ ] Primary vault missing → clear error: "Primary vault '<name>' not found. Set a new primary: `mn vault set-primary <name>`"

### Tests (Phase 1d) — 46 tests

#### Migration Tests (9)
- [ ] Migration: detect single-vault layout → auto-create registry with primary
- [ ] Migration: `github.repo` in config → vault registry `github` field
- [ ] Migration: `collections.yaml` exists → merge into `maho.yaml` + delete old file
- [ ] Migration: `getting-started/` embedded dir preserved (no auto-delete)
- [ ] Migration: `VaultResolver` with no registry → single-vault backward compat
- [ ] Migration: `$MN_VAULT` with vault name → resolves to registered vault
- [ ] Migration: `$MN_VAULT` with path (legacy) → resolves directly
- [ ] Migration: first invocation prints summary of changes
- [ ] Migration: already-migrated vault → no-op

#### Sync Hardening Tests (10)
- [ ] Auth: `--status` shows token source and masked value
- [ ] Auth: clear error when no token available
- [ ] Auth: `gh` installed but not logged in → treated as absent, shows guidance
- [ ] Auth: stored token invalid (401) → clear error + prompt re-auth
- [ ] Pre-flight: `git` not found → friendly install guidance
- [ ] Sync: post-clone valid vault (`maho.yaml` present) → succeeds
- [ ] Sync: post-clone markdown repo without `maho.yaml` → warning + suggest `mn init`
- [ ] Sync: post-clone code repo (no content `.md` files) → error, refused
- [ ] Conflict: rebase conflict → abort → merge fallback → `.conflict-*` file created
- [ ] `.gitignore`: `.maho/` entry verified/added on sync

#### Multi-Vault Tests (27)
- [ ] Registry: create, load, save, validate (iCloud container path)
- [ ] Registry: type-based path resolution (icloud/github/local → correct platform paths)
- [ ] Registry: CLI local cache read/write for offline access
- [ ] `mn vault add --icloud` → creates iCloud vault subdirectory + registers
- [ ] `mn vault add` with GitHub repo → clone + register
- [ ] `mn vault add --readonly` → access set correctly
- [ ] `mn vault add --import` → auto-generates maho.yaml for non-Maho repo
- [ ] `mn vault add` with existing name → error
- [ ] `mn vault add --path` with nonexistent path → error at registration
- [ ] `mn vault remove` → unregister, files remain
- [ ] `mn vault remove --delete` → unregister + files deleted
- [ ] `mn vault set-primary` → updates default
- [ ] `mn vault list` shows all vaults with correct info
- [ ] `mn vault list` marks missing vault path as `missing`
- [ ] `--vault <name>` flag routes to correct vault
- [ ] `--vault <name>` with missing path → friendly error + remediation
- [ ] Cross-vault op with one vault missing → skip + warn, others proceed
- [ ] Primary vault missing → clear error with guidance
- [ ] Read-only: `mn new` blocked, `mn sync` pull-only, `mn publish` blocked
- [ ] Cross-vault search returns results from multiple vaults
- [ ] Cross-vault search results include vault name prefix
- [ ] `mn sync --reindex` triggers FTS index rebuild
- [ ] `mn sync --all` syncs all vaults, `mn sync --vault <name>` syncs one
- [ ] `mn init` interactive wizard creates vault + registry
- [ ] `mn init` adds getting-started as read-only vault (online)
- [ ] `mn init --no-tutorial` skips getting-started vault
- [ ] `mn init` offline → tutorial skipped gracefully, primary vault still created

## Phase 2 — Universal App (macOS + iPadOS + iOS)

- [ ] Xcode project with macOS + iOS targets (universal app)
- [ ] SwiftUI: NavigationSplitView (auto-adapts: sidebar/split/push)
- [ ] Markdown rendering (swift-markdown + WKWebView for KaTeX/Mermaid)
- [ ] Editor with live preview (split on macOS/iPad, toggle on iPhone)
- [ ] iCloud sync (default, vault in iCloud container)
- [ ] GitHub sync (optional, for cross-Apple-ID / AI agent use)
- [ ] GitHub OAuth via `ASWebAuthenticationSession` (replaces Phase 1c token-based auth)
- [ ] Conflict UI: ⚠️ badge on conflicted notes, user opens both files to resolve, deleting `.conflict-*` clears badge
- [ ] Local SQLite metadata + FTS5
- [ ] CJK tokenizer already available via `swift-cjk-sqlite` (from Phase 1b)

## Phase 3 — Vector Search

- [ ] On-device embedding (Apple NLEmbedding as default)
- [ ] sqlite-vec integration
- [ ] Downloadable model tiers (MiniLM → e5-small → BGE-M3 via CoreML)
- [ ] Settings UI: model selection per device
- [ ] Hybrid search (FTS5 + vector RRF)
- [ ] CLI: `mn index --model <tier>`

## Phase 4 — Publishing (All Platforms)

- [ ] Static site generator in MahoNotesKit
- [ ] GitHub OAuth via `ASWebAuthenticationSession` (iOS/iPadOS/macOS)
- [ ] Generate HTML with syntax highlighting, KaTeX, ruby annotation
- [ ] Push to user's GitHub repo → GitHub Pages (REST API)
- [ ] CLI: `mn publish`, `mn publish --preview`
- [ ] Published site: index page, collection pages, RSS feed

## Phase 5 — Polish + App Store

- [ ] Multilingual UI (中文 / English / 日本語 / 한국어)
- [ ] Ruby annotation rendering (native + published sites) — furigana, Tâi-lô, Zhuyin, etc.
- [ ] Mermaid diagrams
- [ ] RSS feed + Open Graph meta tags
- [ ] Share extension (iOS/iPadOS)
- [ ] Export (PDF, EPUB)
- [ ] Customizable published site themes
- [ ] App Store submission
