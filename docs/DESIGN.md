# Maho Notes — Design Overview

> A multilingual personal knowledge base with beautiful markdown rendering, cross-platform native apps, on-device vector search, and selective publishing.

## Overview

Maho Notes is a markdown-first knowledge management system with first-class support for **Chinese (中文)**, **English**, **Japanese (日本語)**, and **Korean (한국어)**. It supports multiple vaults (personal, work, community reference), multiple collections within each vault, on-device multilingual semantic search across all vaults, and the ability to selectively publish notes as public web pages via GitHub Pages. Works offline, syncs via iCloud, and optionally integrates with GitHub for version control, sharing, and publishing.

### Multilingual Support 🌐
- **UI**: Chinese, English, Japanese, Korean (user-selectable)
- **Content**: Full Unicode support, mixed-language notes
- **Search**: FTS5 + vector search work across all four languages (powered by [`swift-cjk-sqlite`](https://github.com/mahopan/swift-cjk-sqlite))
- **Ruby annotation**: `{base|annotation}` syntax — works for Japanese furigana (`{漢字|かんじ}`), Taiwanese Tâi-lô (`{台灣|Tâi-oân}`), Chinese Zhuyin/Pinyin (`{漢字|ㄏㄢˋ ㄗˋ}`), Korean Hanja (`{韓國|한국}`), etc.
- **Embedding models**: Multilingual semantic search across 中英日韓 (built-in tier has limited CJK quality; Light tier and above recommended)

## Architecture

```
┌───────────────────────────┐  ┌──────────┐
│   Universal App (SwiftUI)  │  │   CLI    │
│  macOS + iPadOS + iOS      │  │  (mn)    │
└──────────┬────────────────┘  └────┬─────┘
           │                        │
     ┌─────▼────────────────────────▼──────┐
     │           MahoNotesKit              │
     │  (Markdown, Search, CRUD, Sync)     │
     └──┬────────┬──────────┬──────┬───────┘
        │        │          │      │
        │   ┌────▼────────┐ │  ┌───▼──────┐
        │   │swift-cjk-   │ │  │Embeddings│
        │   │sqlite       │ │  │(on-device)│
        │   │FTS5 + CJK   │ │  │CoreML/NL │
        │   │tokenizer    │ │  └──────────┘
        │   └──┬──────────┘ │
        │  ┌───▼─────┐  ┌──▼──────┐
        │  │Per-vault │  │sqlite-  │
        │  │FTS index │  │vec      │
        │  └─────────┘  └─────────┘
        │
  ┌─────▼──────────────────────────────────────────────┐
  │                  Vault Registry                     │
  │         (iCloud container: vaults.yaml)             │
  │                                                     │
  │  ┌──────────────┐ ┌──────────────┐ ┌────────────┐  │
  │  │ Primary Vault│ │ Work Vault   │ │ Community  │  │
  │  │ (iCloud+Git) │ │ (iCloud)     │ │ (read-only)│  │
  │  │ read-write   │ │ read-write   │ │ pull-only  │  │
  │  └──────┬───────┘ └──────┬───────┘ └──────┬─────┘  │
  └─────────┼────────────────┼────────────────┼────────┘
            │                │                │
    ┌───────▼───┐    ┌──────▼──────┐   ┌─────▼──────┐
    │  iCloud    │    │   GitHub    │   │   GitHub   │
    │  (auto)    │    │  (owned)    │   │  (public)  │
    └───────┬───┘    └──────┬──────┘   └────────────┘
            │               │
            │        ┌──────▼──────┐
            │        │ GitHub Pages│
            │        │ (published) │
            │        └─────────────┘
            │
  Cross-vault search spans all vaults (FTS5 + vector)

Sync: iCloud (automatic per vault) + GitHub (explicit, mn sync)
Vaults: iCloud (multi-vault in container) / GitHub (clone) / Local (macOS CLI)
Publishing: Vault → static HTML → user's GitHub repo → GitHub Pages
```

## Repositories (Our Instance)

| Repo | Visibility | Content |
|------|-----------|---------|
| `kuochuanpan/maho-notes` | Public | App + CLI source code, design docs (open source) |
| `kuochuanpan/maho-vault` | Private | Our personal vault (other users create their own) |
| `mahopan/swift-cjk-sqlite` | Public | SQLite 3.48 + FTS5 + CJK tokenizer (SPM dependency) |
| `kuochuanpan/maho-getting-started` | Public | Tutorial vault — auto-added on `mn init` as read-only vault |

### Importing External Repos

Any public GitHub markdown repo can be added as a **read-only vault** via `mn vault add`:

```bash
mn vault add cheatsheets --github detailyang/awesome-cheatsheet --readonly
mn vault add rust-guide --github nicenemo/master-rust --readonly
```

Non-Maho repos (no `maho.yaml`) are auto-detected and can be imported with `--import`, which generates `maho.yaml` from the directory structure. Read-only vaults pull upstream changes on `mn sync` but never push local edits back.

Other users' **Maho vaults** (repos with `maho.yaml`) work natively — just add them as a vault and they sync like any other.

## Tech Stack Summary

| Component | Technology |
|-----------|-----------|
| CLI | Swift (shares MahoNotesKit) |
| Native App | SwiftUI universal app (macOS + iPadOS + iOS, one project) |
| Shared Logic | MahoNotesKit (Swift Package) — markdown, search, sync, CRUD |
| Published Sites | Static HTML generated by app, hosted on user's GitHub Pages |
| Markdown | swift-markdown (native), Swift HTML templates (static site generator) |
| Syntax Highlighting | TreeSitter (native app, code block highlighting), Splash (Swift-native, static site fallback), highlight.js (static site) |
| Math | WKWebView + KaTeX (native), KaTeX (static site) |
| Ruby Annotation | `{base|annotation}` → `<ruby>` (web) / AttributedString (native) — furigana, Tâi-lô, Zhuyin, Pinyin, etc. |
| Database | [`swift-cjk-sqlite`](https://github.com/mahopan/swift-cjk-sqlite) (SQLite 3.48 + FTS5 + CJK tokenizer) + sqlite-vec |
| Embeddings | Tiered: Apple NLEmbedding (built-in) / all-MiniLM-L6-v2 multilingual (90MB) / multilingual-e5-small (470MB) / BGE-M3 (2.2GB) |
| Embedding Runtime | CoreML (default), MLX (optional, faster on Apple Silicon for large models like BGE-M3) |
| Sync | iCloud (app default) + GitHub (CLI/power user/publishing) |
| Git | Shell out to `git` (CLI) / GitHub REST API (iOS + macOS app, for sync + publishing) |
| Auth | GitHub OAuth via `ASWebAuthenticationSession` (iOS/macOS) / `gh auth` (CLI) |
| Hosting | GitHub Pages (user-owned, for published notes) |
| Domain | notes.pcca.dev |

## Documentation

| Doc | Contents |
|-----|----------|
| [Data Model](data-model.md) | Note structure, frontmatter, config (`maho.yaml`), directory layout |
| [CLI Reference](cli.md) | All `mn` commands, AI agent workflow, global flags, vault resolution |
| [Sync Strategy](sync-strategy.md) | iCloud + GitHub sync, multi-vault architecture, vault registry, conflict handling |
| [Search](search.md) | FTS5, vector search, embedding models, search modes |
| [Native App](app.md) | SwiftUI universal app, markdown rendering, editor, platform adaptation |
| [Publishing](publishing.md) | Static site generation, GitHub Pages, incremental publishing |
| [Design Decisions](decisions.md) | Decision log (#1–#16) |

## Implementation

Implementation phases will be planned after design freeze. These docs describe the **target state** — what Maho Notes will look like when complete.

---

*Design by 真帆 🔭 — 2026-03-04*
