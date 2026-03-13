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
- **Storage**: sqlite-vec extension for vector similarity queries via [`SQLiteVec`](https://github.com/jkrukowski/SQLiteVec) Swift package
- **Embedding runtime**: [`swift-embeddings`](https://github.com/jkrukowski/swift-embeddings) — pure Swift, runs HuggingFace models locally via MLTensor (macOS 15+ / iOS 18+)
- Each device has its own local embedding DB (not synced between devices)
- Markdown files sync via iCloud/GitHub; each device generates its own embeddings locally
- User can choose embedding model per device (bigger Mac → bigger model, iPhone → smaller model)

### Why Not Sync Embeddings?
- Different devices may use different models (different dimensions)
- Embedding DB can be regenerated from markdown anytime
- Avoids syncing large binary blobs
- Each device optimizes for its own hardware

### Why Not Apple NLEmbedding?
- Tested on Mac mini M4 (macOS 26.3): **only English** available for both word and sentence embeddings
- No Japanese, Korean, Traditional Chinese, or Simplified Chinese support
- Apple Intelligence multilingual expansion covers Writing Tools, not NLEmbedding API
- Using `swift-embeddings` with HuggingFace models provides consistent multilingual support across all platforms
- See [Decision #21](#21-drop-nlembedding-use-swift-embeddings)

## Embedding Models (User-Selectable)

| Tier | Model | Size | Dim | Quality | Platforms |
|------|-------|------|-----|---------|-----------|
| 🟢 Default | all-MiniLM-L6-v2 (multilingual) | ~90 MB | 384 | Good | All |
| 🟡 Standard | multilingual-e5-small | ~470 MB | 384 | Better | All |
| 🔴 Pro | multilingual-e5-large | ~2.2 GB | 1024 | Best | Mac recommended |

All models run via `swift-embeddings` (MLTensor). No CoreML conversion needed — models loaded directly from HuggingFace safetensors format.

- **Default**: all-MiniLM-L6-v2 (90MB, 50+ languages including 中日韓英, good quality for most use cases)
- **Optional**: User downloads preferred model in Settings → Search → Embedding Model
- **Per-device choice**: iPhone can use Default (90MB), Mac can use Pro (2.2GB) — independent
- Models distributed via:
  - **On-Demand Resources (ODR)** for App Store builds (Apple-managed CDN, lazy download)
  - **Direct download** from HuggingFace Hub for CLI / sideloaded builds (auto-cached in `~/.maho/models/`)
  - App prompts user before downloading; shows model size + expected quality improvement

## Embedding Pipeline (Per Device)

1. Note created/updated → markdown syncs to device via iCloud/GitHub
2. Device detects new/changed notes → queues for local embedding
3. Background task runs selected model via `swift-embeddings` → generates embeddings
4. Stored in local SQLite (sqlite-vec) — **not synced** (each device has its own)
5. Query: embed search string locally → cosine similarity → top-K results

## Search Modes

| Mode | Command | Description |
|------|---------|-------------|
| **Full-text** | `mn search "query"` | FTS5 with CJK tokenizer — always available, instant |
| **Semantic** | `mn search --semantic "query"` | Vector similarity — requires local indexing first |
| **Hybrid** | `mn search --hybrid "query"` | FTS5 + vector combined via RRF (Reciprocal Rank Fusion) |
| **Scoped** | `mn search --collection japanese "query"` | Limit to one collection |
| **Vault-scoped** | `mn search --vault personal "query"` | Limit to one vault |
| **Cross-vault** | `mn search "query"` (default) | Search across all vaults |

Cross-vault search results include vault name prefix: `[personal] japanese/grammar/kunyomi-onyomi` vs `[cheatsheets] git/basics.md`.

## Chunking Strategy

Notes are split into chunks before embedding. Each chunk gets its own vector in the index.
See [Decision #22](#22-heading-based-chunking).

### Rules
- **Short notes** (< 512 tokens): embed the entire note as a single chunk (title prepended)
- **Long notes** (≥ 512 tokens): split by markdown headings (`#`, `##`, `###`, etc.)
  - Each chunk = heading section content, prefixed with the note's title for context: `"{title}: {chunk_text}"`
  - If a heading section itself exceeds 512 tokens, split further by paragraphs
- **Frontmatter**: not embedded (title and tags are already in FTS5; embedding the YAML block adds noise)
- **No overlap**: heading-based splits have natural semantic boundaries; overlap adds complexity with minimal gain for our note-sized documents

### Schema
```sql
-- Vector embeddings table (sqlite-vec virtual table)
CREATE VIRTUAL TABLE vec_chunks USING vec0(
  embedding float[384]    -- dimension depends on model; 384 for MiniLM/e5-small
);

-- Chunk metadata (regular table, joined with vec_chunks by rowid)
CREATE TABLE chunks(
  id INTEGER PRIMARY KEY,  -- matches vec_chunks rowid
  path TEXT NOT NULL,       -- note relative path
  chunk_id INTEGER NOT NULL, -- 0-based index within note
  chunk_text TEXT NOT NULL,  -- original text (for snippet display)
  model TEXT NOT NULL,       -- model identifier used for embedding
  mtime REAL NOT NULL        -- note file mtime when embedded
);
CREATE INDEX idx_chunks_path ON chunks(path);
```

### Semantic Search Result Aggregation
- Vector search returns chunks, not notes
- Results are aggregated to note level: best chunk score per note → note score
- Snippet shows the best-matching chunk text

## Hybrid Search (RRF)

Reciprocal Rank Fusion merges FTS5 and vector search results without score normalization.
See [Decision #23](#23-rrf-parameters).

### Algorithm
```
For each result set (FTS5, vector):
  For each document at rank r (1-based):
    rrf_score += 1 / (k + r)

Final ranking = sort by total rrf_score descending
```

### Parameters
- **k = 60** (industry standard, used by Elasticsearch, Azure AI Search)
- **Weight ratio**: 1:1 (FTS5 and vector contribute equally)
- **Top-N per source**: each source returns top 50 results before fusion
- **Minimum score threshold**: none (RRF scores are relative, thresholding is not meaningful)

### Behavior by Search Mode
| Flag | FTS5 | Vector | Fusion |
|------|:----:|:------:|:------:|
| *(default, no vector index)* | ✅ | — | FTS5 only |
| *(default, vector index exists)* | ✅ | — | FTS5 only (explicit opt-in for hybrid) |
| `--semantic` | — | ✅ | Vector only |
| `--hybrid` | ✅ | ✅ | RRF merge |

**Graceful degradation**: `--hybrid` without a vector index silently falls back to FTS5 only (with a stderr warning). `--semantic` without a vector index prints an error and suggests `mn index --model <name>`.

## Incremental Indexing

`mn index` compares each note's file mtime against the last-indexed timestamp stored in a `_meta` table. Only changed/new files are re-indexed; deleted files are pruned.

```bash
mn index                    # incremental (mtime-based diff)
mn index --full             # drop and rebuild from scratch
mn index --model e5-large     # specify embedding model
mn index --vault <name>     # index specific vault
mn index --all              # index all vaults
```

**FTS5 schema:**
- Table: `notes_fts(path, title, tags, body)` with tokenizer `cjk`
- `_meta` table: `(path TEXT PRIMARY KEY, mtime REAL, indexed_at REAL)`
- `_schema` table for version tracking (current: v1)
- LIKE fallback for NLTokenizer segmentation edge cases

**CLI embedding:**
- CLI uses same model selection: `mn index --model e5-large` or `mn index --model minilm`
- Embedding runtime: `swift-embeddings` (MLTensor) — loads HuggingFace models directly, no CoreML conversion needed
- Model auto-download: first `mn index` with a new model downloads from HuggingFace Hub → cached in `~/.maho/models/`
- `EmbeddingProvider` protocol: `func embed(_ text: String) async throws -> [Float]` + `func embedBatch(_ texts: [String]) async throws -> [[Float]]` + `var dimensions: Int`
