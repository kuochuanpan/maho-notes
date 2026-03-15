---
title: 5. Search
tags: [tutorial]
created: 2026-03-14T00:00:00-05:00
updated: 2026-03-14T00:00:00-05:00
public: false
---

# 5. Search

Maho Notes has powerful search that works across all your notes — in any language.

## Search Modes

Maho Notes offers three search modes, which you can switch in the search bar or in **Settings**:

### Text Search (Default)

Full-text keyword search powered by a CJK-aware engine. Works out of the box — no setup needed.

- Searching `漢字` finds notes containing 漢字, even within longer words
- Mixed-language notes are fully searchable

This is the default mode and works great for most use cases.

### Semantic Search

Finds notes by *meaning*, not just exact words. For example, searching "how stars are born" can find a note titled "Stellar Formation Process" even if it doesn't contain those exact words.

**Setup required:** Semantic search uses an on-device AI embedding model. Go to **Settings → Search → Embedding Model** to download one:

| Model | Size | Best For |
|-------|------|----------|
| MiniLM-L6-v2 | ~80 MB | English notes, fastest |
| Multilingual E5 Small | ~120 MB | Multi-language, good balance |
| Multilingual E5 Large | ~2.2 GB | Best quality, needs more storage |

After downloading a model, tap **Build Vector Index** in Settings to index your notes. This runs entirely on-device — your notes never leave your device.

### Hybrid Search

Combines text and semantic search for the best of both worlds. Results from both methods are merged and ranked together.

**Setup:** Same as semantic search — requires a downloaded embedding model and built vector index.

## How to Search

Use the search bar (or press **⌘K** on Mac) to search across all notes in your vault. Results are ranked by relevance and shown instantly.

## Tips

- **Start with text search** — It works immediately and handles most needs
- **Try semantic search** for exploratory queries when you don't remember the exact words
- **Multilingual users** — Choose the E5 Small or E5 Large model for best CJK + English results
- **Collection scope** — Search within a specific collection for focused results
