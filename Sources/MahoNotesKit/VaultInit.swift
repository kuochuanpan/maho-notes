import Foundation

/// Core vault initialization logic. Extracted so it can be tested with temp directories.
public func initVault(
    vaultPath: String,
    authorName: String,
    githubRepo: String,
    skipTutorial: Bool,
    globalConfigDir: String
) throws {
    let fm = FileManager.default

    // --- Global ~/.maho/ setup ---
    if !fm.fileExists(atPath: globalConfigDir) {
        try fm.createDirectory(atPath: globalConfigDir, withIntermediateDirectories: true)
    }

    let globalConfigPath = (globalConfigDir as NSString).appendingPathComponent("config.yaml")
    if !fm.fileExists(atPath: globalConfigPath) {
        let skeleton = """
        # Maho Notes — global device config
        # Auth tokens and device-specific settings
        auth: {}
        embed:
          model: builtin
        """
        try skeleton.write(toFile: globalConfigPath, atomically: true, encoding: .utf8)
        print("Created ~/.maho/config.yaml")
    }

    // --- Vault directory ---
    if !fm.fileExists(atPath: vaultPath) {
        try fm.createDirectory(atPath: vaultPath, withIntermediateDirectories: true)
        print("Created vault at \(vaultPath)")
    }

    // --- maho.yaml ---
    let mahoYaml = (vaultPath as NSString).appendingPathComponent("maho.yaml")
    if !fm.fileExists(atPath: mahoYaml) {
        let collectionsSection: String
        if skipTutorial {
            collectionsSection = "collections: []"
        } else {
            collectionsSection = """
            collections:
              - id: getting-started
                name: Getting Started
                icon: questionmark.circle
                description: Tutorial — how to use Maho Notes (safe to delete)
            """
        }
        let content = """
        author:
          name: "\(authorName)"
          url: ""
        \(collectionsSection)
        github:
          repo: "\(githubRepo)"
        site:
          domain: ""
          title: My Notes
          theme: default
        """
        try content.write(toFile: mahoYaml, atomically: true, encoding: .utf8)
        print("Created maho.yaml")
    }

    // --- .maho/ directory ---
    let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
    if !fm.fileExists(atPath: mahoDir) {
        try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
        print("Created .maho/")
    }

    // --- .gitignore ---
    let gitignorePath = (vaultPath as NSString).appendingPathComponent(".gitignore")
    if !fm.fileExists(atPath: gitignorePath) {
        try ".maho/\n".write(toFile: gitignorePath, atomically: true, encoding: .utf8)
        print("Created .gitignore")
    } else {
        let existing = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        if !existing.contains(".maho/") && !existing.contains(".maho\n") {
            try (existing + "\n.maho/\n").write(toFile: gitignorePath, atomically: true, encoding: .utf8)
            print("Updated .gitignore with .maho/ entry")
        }
    }

    // --- Tutorial notes ---
    if !skipTutorial {
        let gsDir = (vaultPath as NSString).appendingPathComponent("getting-started")
        if !fm.fileExists(atPath: gsDir) {
            try fm.createDirectory(atPath: gsDir, withIntermediateDirectories: true)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        let now = dateFormatter.string(from: Date())

        let tutorialNotes: [(filename: String, content: String)] = [
            ("_index.md", """
             ---
             title: Getting Started
             description: Tutorial — how to use Maho Notes
             ---

             # Getting Started

             Welcome to Maho Notes! This collection walks you through the basics.
             """),
            ("001-your-first-note.md", """
             ---
             title: Your First Note
             tags: [tutorial]
             created: \(now)
             updated: \(now)
             public: false
             order: 1
             ---

             # Your First Note

             Create a new note with:

             ```bash
             mn new "My Note" --collection getting-started
             ```

             Notes are markdown files with YAML frontmatter.
             """),
            ("002-collections.md", """
             ---
             title: Collections
             tags: [tutorial]
             created: \(now)
             updated: \(now)
             public: false
             order: 2
             ---

             # Collections

             Collections are top-level directories in your vault.
             Define them in `maho.yaml` under the `collections:` key.

             ```bash
             mn collections    # list all collections
             mn list           # list notes grouped by collection
             ```
             """),
            ("003-markdown-features.md", """
             ---
             title: Markdown Features
             tags: [tutorial, markdown]
             created: \(now)
             updated: \(now)
             public: false
             order: 3
             ---

             # Markdown Features

             Maho Notes supports CommonMark + GFM with extensions:

             - **Math**: `$E = mc^2$` and `$$...$$` blocks (KaTeX)
             - **Diagrams**: Mermaid code blocks
             - **Ruby annotation**: `{漢字|かんじ}` for furigana and phonetic guides
             - **Tables**, task lists, footnotes
             """),
            ("004-search.md", """
             ---
             title: Search
             tags: [tutorial]
             created: \(now)
             updated: \(now)
             public: false
             order: 4
             ---

             # Search

             Search across all notes:

             ```bash
             mn search "query"              # full-text search
             mn search --collection japanese "query"  # scoped search
             ```
             """),
            ("005-sync-and-github.md", """
             ---
             title: Sync & GitHub
             tags: [tutorial, sync]
             created: \(now)
             updated: \(now)
             public: false
             order: 5
             ---

             # Sync & GitHub

             Your vault syncs via iCloud by default. For GitHub sync:

             ```bash
             mn config auth                    # set up GitHub auth
             mn config set github.repo user/vault  # set repo
             mn sync                           # pull + push
             ```
             """),
            ("006-publishing.md", """
             ---
             title: Publishing
             tags: [tutorial, publishing]
             created: \(now)
             updated: \(now)
             public: false
             order: 6
             ---

             # Publishing

             Publish notes as a static site on GitHub Pages:

             ```bash
             mn meta <path> --set public=true  # mark as public
             mn publish                        # deploy to GitHub Pages
             ```
             """),
        ]

        var createdAny = false
        for note in tutorialNotes {
            let filePath = (gsDir as NSString).appendingPathComponent(note.filename)
            if !fm.fileExists(atPath: filePath) {
                try note.content.write(toFile: filePath, atomically: true, encoding: .utf8)
                createdAny = true
            }
        }
        if createdAny {
            print("Created getting-started/ tutorial notes")
        }
    }

    print("Vault initialized at \(vaultPath)")
}
