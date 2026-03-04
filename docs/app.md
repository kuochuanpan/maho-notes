# Native App (Universal, SwiftUI)

One Xcode project, shared SwiftUI codebase. Supports **macOS**, **iOS**, and **iPadOS**.

## MahoNotesKit (Swift Package — Shared Logic)

- Markdown parsing + rendering
- iCloud sync (primary) + Git operations (optional, for CLI/publishing)
- SQLite + FTS5 + sqlite-vec (vector search)
- On-device embedding (CoreML / NLEmbedding)
- Collection/note CRUD
- Static site generator (for publishing)

## Platform Adaptation (NavigationSplitView)

| Platform | Layout | Notes |
|----------|--------|-------|
| **macOS** | Three-column sidebar | 3 view modes: preview / editor / split (default: preview) |
| **iPadOS** | Two/three-column split view | Same 3 view modes in landscape; Stage Manager multi-window |
| **iPhone** | Single-column push navigation | Compact UI, toggle view/edit |

## macOS

- Editor view modes (toggle via toolbar or shortcut):
  - **Preview only** — 閱讀模式，純渲染（預設）
  - **Editor only** — 純 markdown 編輯
  - **Split view** — 左 markdown / 右 live preview（side by side）
- Keyboard shortcuts: Cmd+N (new), Cmd+S (save), Cmd+F (search), Cmd+Shift+F (global search), Cmd+E (toggle edit mode)

## iPadOS

- Same 3 view modes as macOS (preview / editor / split) in landscape; push navigation in portrait on smaller iPads
- Keyboard shortcuts (same as macOS when external keyboard connected)
- Drag & drop support
- Stage Manager: multiple windows

## iPhone

- Push navigation, compact layout
- Toggle between view/edit mode
- Pull to sync
- Share sheet for publishing

## Editor (Shared)

- Raw markdown editor with:
  - Syntax highlighting for markdown
  - Live preview (3 view modes on macOS/iPadOS, toggle on iPhone)
  - Toolbar shortcuts (bold, italic, heading, link, image, code block, table, ruby annotation)
  - Auto-save on pause

## Markdown Rendering

### Must Support
- **CommonMark + GFM** (tables, task lists, strikethrough, autolinks)
- **Syntax highlighting** — all major languages (Python, Swift, Rust, C++, Fortran, bash, JS/TS)
- **Math** — KaTeX (inline `$...$` and block `$$...$$`)
- **Diagrams** — Mermaid
- **Images** — local (relative path) + remote URL
- **Admonitions / callouts** — tip, warning, note, info blocks
- **Table of contents** — auto-generated from headings
- **Footnotes**
- **Ruby annotation** — `{base|annotation}` syntax for phonetic guides, language-agnostic:
  - Japanese furigana: `{漢字|かんじ}`
  - Taiwanese Tâi-lô/POJ: `{台灣|Tâi-oân}`
  - Chinese Zhuyin: `{漢字|ㄏㄢˋ ㄗˋ}`
  - Chinese Pinyin: `{漢字|hànzì}`
  - Korean readings: `{韓國|한국}`

### Rendering Stack
- **Native (SwiftUI)**: `swift-markdown` for parsing → custom `AttributedString` renderer, `WKWebView` fallback for complex content (KaTeX, Mermaid)
- **Static Site Generator** (for publishing): Swift-native HTML generation using templates (e.g., `Plot` or custom Swift DSL). Syntax highlighting via `Splash` (Swift) or pre-built highlight.js bundle. KaTeX/Mermaid via bundled JS in the generated HTML.
- **CLI** (macOS / Linux): terminal-friendly output (no rendering needed, just metadata + search results)
