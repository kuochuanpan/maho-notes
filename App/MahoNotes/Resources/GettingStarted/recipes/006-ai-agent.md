---
title: "Recipe: AI Agent Integration"
tags: [recipe]
created: 2026-03-15T00:00:00-05:00
updated: 2026-03-15T00:00:00-05:00
public: false
---

# AI Agent Integration

Maho Notes is designed to work with AI agents out of the box. Since your notes are plain markdown files with a powerful CLI, any AI assistant can read, search, create, and organize your knowledge base.

## How It Works

The `mn` CLI has a built-in agent guide:

```bash
mn skill          # human-readable usage guide for AI agents
mn skill --json   # machine-readable version
```

AI agents (like [OpenClaw](https://openclaw.ai)) can use `mn` commands just like you would — no special API needed.

## What an AI Agent Can Do

### 📝 Create Notes from Conversations

After a meeting or brainstorming session, your agent can capture the discussion:

```bash
mn new "Weekly Sync — March 15" --collection meetings
# Then edit the file directly to add content
```

### 🔍 Search Your Knowledge Base

Ask your agent: *"What did we decide about the API redesign?"*

```bash
mn search "API redesign" --hybrid
```

The hybrid search combines keyword matching with semantic understanding — so it finds relevant notes even if the exact words don't match.

### 📊 Summarize & Connect

Your agent can read multiple notes and find connections:

```bash
mn show meetings/2026-03-15-weekly-sync.md --body-only
mn show reading-notes/attention-is-all-you-need.md --body-only
mn search "transformer architecture" --semantic --limit 5
```

### 📚 Build a Research Library

Your agent can create structured reading notes after you discuss a paper:

```bash
mn new "Vaswani et al 2017 — Attention Is All You Need" --collection reading-notes
```

Then write a review with equations, diagrams, and your key takeaways — all in markdown.

### 🔄 Keep Everything in Sync

```bash
mn sync          # push changes to GitHub
mn index         # update search index
```

## Example: OpenClaw + Maho Notes

[OpenClaw](https://openclaw.ai) is an AI assistant framework that can use Maho Notes as its knowledge backend. Here's what a typical workflow looks like:

1. **You chat** with your AI assistant about a topic
2. **The agent searches** your existing notes for context (`mn search`)
3. **You discuss and decide** — the agent has relevant history at hand
4. **The agent writes** key decisions and insights to your vault (`mn new` + file edit)
5. **Sync happens** automatically — your notes are backed up and accessible everywhere

> [!tip]
> The `mn skill` command outputs everything an AI agent needs to know about using the CLI correctly — including which operations to use `mn` for and which to do via direct file editing.

## The Agent-Friendly Design

Maho Notes follows principles that make it naturally AI-compatible:

| Principle | Why It Helps Agents |
|-----------|-------------------|
| **Plain markdown files** | Agents can read and write without special APIs |
| **Structured frontmatter** | Metadata is predictable and parseable |
| **CLI with `--json` output** | Every command has machine-readable output |
| **Built-in `mn skill`** | Self-documenting — agents learn the tool instantly |
| **FTS5 + semantic search** | Agents can find relevant context quickly |
| **File-based = git-friendly** | Full version history, diffs, and collaboration |

## Privacy Note

> [!note]
> Your notes stay on your device and your GitHub repository. The AI agent accesses them through the local CLI — nothing is sent to external servers unless you explicitly sync or publish.

This is what "local-first AI" looks like: your data stays yours, and the AI meets you where your files are.
