# Search

## FTS5 Full-Text Search

- **Engine**: SQLite FTS5 with **`cjk` tokenizer** ([`swift-cjk-sqlite`](https://github.com/mahopan/swift-cjk-sqlite)) — Apple NLTokenizer for CJK segmentation
- **Scope**: title + content + tags, always available, instant
- **Ranking**: BM25 with column weights — title (10.0) > tags (5.0) > body (1.0)
- **Index location**: `.maho/index.db` (gitignored, not synced — each device builds its own)
- **Auto-build**: When `mn search` is invoked and no `index.db` exists, automatically build the index first and print a one-time notice (`Building search index...`)
- **Fallback**: If `index.db` is corrupted or schema version mismatches, fall back to substring search and warn the user to run `mn index --full`

## Vector Search

### Architecture
- **100% on-device** — no server dependency (App Store requirement)
- Each device has its own local embedding DB (not synced between devices)
- Markdown files sync via iCloud/GitHub; each device generates its own embeddings locally
- User can choose embedding model per device (bigger Mac → bigger model, iPhone → smaller model)

### Why Not Sync Embeddings?
- Different devices may use different models (different dimensions)
- Embedding DB can be regenerated from markdown anytime
- Avoids syncing large binary blobs
- Each device optimizes for its own hardware

## Embedding Models (User-Selectable)

| Tier | Model | Size | Dim | Quality | Platforms |
|------|-------|------|-----|---------|-----------|
| 🟢 Built-in | Apple NLEmbedding | 0 MB | varies | Basic (⚠️ CJK quality limited) | All (iOS 17+, macOS 14+) |
| 🟡 Light | all-MiniLM-L6-v2 (multilingual) | ~90 MB | 384 | Good | All |
| 🟠 Standard | multilingual-e5-small | ~470 MB | 384 | Better | All |
| 🔴 Pro | BGE-M3 | ~2.2 GB | 1024 | Best | Mac recommended |

- **Default**: Apple NLEmbedding (zero download, works immediately; note: CJK/Korean quality is limited — for serious multilingual search, recommend Light tier or above)
- **Optional**: User downloads preferred model in Settings → Search → Embedding Model
- **Per-device choice**: iPhone can use Light, Mac can use Pro — independent
- Models distributed as CoreML packages via:
  - **On-Demand Resources (ODR)** for App Store builds (Apple-managed CDN, lazy download)
  - **Direct download** from GitHub Releases for CLI / sideloaded builds
  - App prompts user before downloading; shows model size + expected quality improvement

## Embedding Pipeline (Per Device)

1. Note created/updated → markdown syncs to device via iCloud/GitHub
2. Device detects new/changed notes → queues for local embedding
3. Background task runs selected model → generates embeddings
4. Stored in local SQLite (sqlite-vec) — **not synced** (each device has its own)
5. Query: embed search string locally → cosine similarity → top-K results

## Search Modes

| Mode | Command | Description |
|------|---------|-------------|
| **Full-text** | `mn search "query"` | FTS5 with CJK tokenizer — always available, instant |
| **Semantic** | `mn search --semantic "query"` | Vector similarity — requires local indexing first |
| **Hybrid** | *(automatic)* | FTS5 score + vector score combined via RRF (Reciprocal Rank Fusion) |
| **Scoped** | `mn search --collection japanese "query"` | Limit to one collection |
| **Vault-scoped** | `mn search --vault personal "query"` | Limit to one vault |
| **Cross-vault** | `mn search "query"` (default) | Search across all vaults |

Cross-vault search results include vault name prefix: `[personal] japanese/grammar/001-...` vs `[cheatsheets] git/basics.md`.

## Incremental Indexing

`mn index` compares each note's file mtime against the last-indexed timestamp stored in a `_meta` table. Only changed/new files are re-indexed; deleted files are pruned.

```bash
mn index                    # incremental (mtime-based diff)
mn index --full             # drop and rebuild from scratch
mn index --model bge-m3     # specify embedding model
mn index --vault <name>     # index specific vault
mn index --all              # index all vaults
```

**FTS5 schema:**
- Table: `notes_fts(path, title, tags, body)` with tokenizer `cjk`
- `_meta` table: `(path TEXT PRIMARY KEY, mtime REAL, indexed_at REAL)`
- `_schema` table for version tracking (current: v1)
- LIKE fallback for NLTokenizer segmentation edge cases

**CLI embedding:**
- CLI uses same model selection: `mn index --model bge-m3` or `mn index --model builtin`
- Embedding runtime: CoreML (default) or MLX (optional, faster on Apple Silicon for large models like BGE-M3)
