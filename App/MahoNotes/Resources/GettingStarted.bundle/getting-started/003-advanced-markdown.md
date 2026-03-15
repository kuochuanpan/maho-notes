---
title: 3. Advanced Markdown
tags: [tutorial, markdown]
created: 2026-03-14T00:00:00-05:00
updated: 2026-03-14T00:00:00-05:00
public: false
---

# 3. Advanced Markdown

Maho Notes supports several markdown extensions beyond the basics.

## Math Equations (KaTeX)

Write math inline with single dollar signs, or as a block with double dollar signs:

**Inline:** `$E = mc^2$` renders as $E = mc^2$

**Block:**

```markdown
$$
\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}
$$
```

$$
\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}
$$

## Diagrams (Mermaid)

Create flowcharts, sequence diagrams, and more using Mermaid:

````markdown
```mermaid
graph LR
    A[Idea] --> B[Draft]
    B --> C[Review]
    C --> D[Publish]
```
````

```mermaid
graph LR
    A[Idea] --> B[Draft]
    B --> C[Review]
    C --> D[Publish]
```

## Ruby Annotations (Furigana)

Add pronunciation guides above characters — works for any language:

```markdown
{漢字|かんじ}     — Japanese furigana
{台灣|Tâi-oân}   — Taiwanese Tâi-lô
{漢字|hànzì}     — Chinese Pinyin
{韓國|한국}       — Korean readings
```

{漢字|かんじ} — Japanese furigana

{台灣|Tâi-oân} — Taiwanese Tâi-lô

## Code Blocks

Syntax highlighting for many languages:

````markdown
```python
def hello():
    print("Hello from Maho Notes!")
```
````

```python
def hello():
    print("Hello from Maho Notes!")
```

## Tables

```markdown
| Planet  | Mass (M☉) | Radius (R☉) |
|---------|-----------|-------------|
| Jupiter | 0.001     | 0.10        |
| Saturn  | 0.0003    | 0.084       |
```

| Planet  | Mass (M☉) | Radius (R☉) |
|---------|-----------|-------------|
| Jupiter | 0.001     | 0.10        |
| Saturn  | 0.0003    | 0.084       |

## Callouts / Admonitions

```markdown
> [!tip]
> This is a helpful tip.

> [!warning]
> Be careful with this step.

> [!note]
> Additional context or explanation.
```

> [!tip]
> This is a helpful tip.

## Footnotes

```markdown
Maho Notes uses SQLite for search[^1].

[^1]: Specifically, FTS5 with a CJK-aware tokenizer.
```

Maho Notes uses SQLite for search[^1].

[^1]: Specifically, FTS5 with a CJK-aware tokenizer.
