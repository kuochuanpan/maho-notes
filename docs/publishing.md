# Publishing

## Philosophy

Maho Notes is a **tool, not a platform**. We don't host anyone's content.
Each user publishes to their own GitHub Pages (or other static hosting).

## Architecture

```
User's App                    User's GitHub
┌──────────┐    generate     ┌─────────────────┐    GitHub Pages
│ Markdown │ ──────────────→ │ user/my-notes    │ ──────────────→ user.github.io/my-notes
│ (public) │   static HTML   │ (public repo)    │                 or custom domain
└──────────┘                 └─────────────────┘
```

## Flow (All Platforms)

1. User connects GitHub account in Settings (OAuth via `ASWebAuthenticationSession` on iOS/macOS)
2. User creates/selects a GitHub repo for publishing (e.g., `user/my-notes`)
3. Mark notes as `public: true` + set `slug` in frontmatter
4. Tap "Publish" → app generates static HTML + pushes to user's repo
5. GitHub Pages serves the site automatically

## Publishing by Platform

| Platform | Auth | Push Method |
|----------|------|-------------|
| iOS / iPadOS | `ASWebAuthenticationSession` (system browser) | GitHub REST API |
| macOS | `ASWebAuthenticationSession` | GitHub REST API or git |
| CLI | `gh auth` or token | git push |

All platforms can publish. No git CLI needed on iOS — pure HTTP API.

## What Gets Published

- Only notes with `public: true` in frontmatter
- Static HTML with beautiful rendering (syntax highlighting, KaTeX, ruby annotation)
- Auto-generated index page, collection pages, RSS feed
- User's private notes never leave their device/iCloud

## User Setup (One-Time)

1. In app: Settings → Publishing → Connect GitHub
2. Create or select a repo (app can create it for the user)
3. Enable GitHub Pages in repo settings (app guides the user)
4. Optional: configure custom domain (e.g., `notes.alice.dev`)

## Incremental Publishing

Publishing is incremental by default. A **publish manifest** (`.maho/publish-manifest.json`) tracks the content hash (SHA-256) of each published note.

On `mn publish`:
1. Scan all `public: true` notes
2. Compute content hash (frontmatter + body) for each
3. Compare with manifest:
   - **Hash changed** → regenerate HTML, include in commit
   - **Hash unchanged** → skip
   - **New `public: true`** → generate HTML
   - **In manifest but now `public: false` or deleted** → remove HTML
4. Single commit + push with all changes

Use `mn publish --force` to regenerate all HTML (e.g., after a theme change).

## CLI

```bash
mn publish                          # incremental — only changed notes
mn publish --force                  # full rebuild
mn publish japanese/grammar/001-kunyomi-onyomi.md  # publish single note
mn unpublish <path>                 # remove from published site
mn publish --preview                # local preview before pushing
```

## Published Site Routes (per user)

```
/                           → Index (list of published collections + notes)
/c/:collection              → Collection page
/c/:collection/:slug        → Published note
/feed.xml                   → RSS feed
```

## Static Site Features

- Clean, responsive theme (light/dark mode)
- Syntax highlighting, KaTeX math, Mermaid diagrams, ruby annotation, admonitions/callouts
- Collection-based navigation
- RSS feed
- Open Graph meta tags for social sharing
- Reading time estimate
- Custom domain support (user configures in GitHub Pages settings)
- SEO-friendly static HTML
- Customizable theme (future: user-selectable themes)

## Multi-Vault Publishing

Each vault can be published independently. A vault's `maho.yaml` contains its own `github.repo` and `site` configuration:

```yaml
# vault-a/maho.yaml
github:
  repo: user/vault-a
site:
  domain: notes.alice.dev
  title: Alice's Notes

# vault-b/maho.yaml
github:
  repo: user/vault-b
site:
  domain: work.alice.dev
  title: Work Notes
```

- `mn publish` publishes from the primary vault by default
- `mn publish --vault <name>` publishes from a specific vault
- Read-only vaults cannot be published (blocked with error)
- Each vault publishes to its own GitHub repo → its own GitHub Pages site
- Cross-vault links are not supported in published sites (each site is self-contained)

## Our Instance

- `notes.pcca.dev` → Kuo-Chuan's personal published notes (our own GitHub Pages)
- Not a shared platform — just our own deployment of the same tool
