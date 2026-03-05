import ArgumentParser
import Foundation
import MahoNotesKit

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new vault or initialize missing files"
    )

    @OptionGroup var vaultOption: VaultOption

    func run() throws {
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath
        let fm = FileManager.default

        // Create vault directory
        if !fm.fileExists(atPath: vaultPath) {
            try fm.createDirectory(atPath: vaultPath, withIntermediateDirectories: true)
            print("Created vault at \(vaultPath)")
        }

        // maho.yaml
        let mahoYaml = (vaultPath as NSString).appendingPathComponent("maho.yaml")
        if !fm.fileExists(atPath: mahoYaml) {
            let content = """
            author:
              name: ""
              url: ""
            collections:
              - id: getting-started
                name: Getting Started
                icon: questionmark.circle
                description: Tutorial — how to use Maho Notes (safe to delete)
            github:
              repo: ""
            site:
              domain: ""
              title: My Notes
              theme: default
            """
            try content.write(toFile: mahoYaml, atomically: true, encoding: .utf8)
            print("Created maho.yaml")
        }

        // .maho/ directory
        let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
        if !fm.fileExists(atPath: mahoDir) {
            try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
            print("Created .maho/")
        }

        // .gitignore with .maho/ entry
        let gitignorePath = (vaultPath as NSString).appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: gitignorePath) {
            let gitignoreContent = ".maho/\n"
            try gitignoreContent.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
            print("Created .gitignore")
        } else {
            let existing = try String(contentsOfFile: gitignorePath, encoding: .utf8)
            if !existing.contains(".maho/") && !existing.contains(".maho\n") {
                let updated = existing + "\n.maho/\n"
                try updated.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
                print("Updated .gitignore with .maho/ entry")
            }
        }

        // getting-started/ collection with tutorial notes
        let gsDir = (vaultPath as NSString).appendingPathComponent("getting-started")
        if !fm.fileExists(atPath: gsDir) {
            try fm.createDirectory(atPath: gsDir, withIntermediateDirectories: true)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        let now = dateFormatter.string(from: Date())

        let tutorialNotes: [(filename: String, title: String, order: Int, content: String)] = [
            ("_index.md", "Getting Started", 0, """
             ---
             title: Getting Started
             description: Tutorial — how to use Maho Notes
             ---

             # Getting Started

             Welcome to Maho Notes! This collection walks you through the basics.
             """),
            ("001-your-first-note.md", "Your First Note", 1, """
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
            ("002-collections.md", "Collections", 2, """
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
            ("003-markdown-features.md", "Markdown Features", 3, """
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
            ("004-search.md", "Search", 4, """
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
            ("005-sync-and-github.md", "Sync & GitHub", 5, """
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
            ("006-publishing.md", "Publishing", 6, """
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

        for note in tutorialNotes {
            let filePath = (gsDir as NSString).appendingPathComponent(note.filename)
            if !fm.fileExists(atPath: filePath) {
                try note.content.write(toFile: filePath, atomically: true, encoding: .utf8)
            }
        }
        print("Created getting-started/ tutorial notes")

        print("Vault initialized at \(vaultPath)")
    }
}
