import ArgumentParser
import Foundation
import MahoNotesKit
import Yams

struct PublishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Publish public notes as a static site"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Path to a note to mark public and publish (optional)")
    var path: String?

    @Flag(name: .long, help: "Full rebuild ignoring manifest")
    var force: Bool = false

    @Flag(name: .long, help: "Generate to temp dir and open in browser")
    var preview: Bool = false

    func run() throws {
        try vaultOption.validateVaultExists()
        try vaultOption.validateWritable()
        let vault = vaultOption.makeVault()
        let vaultPath = vault.path
        let siteConfig = try loadSiteConfig(vaultPath: vaultPath)
        let generator = SiteGenerator(vault: vault, config: siteConfig)

        // Single note publish: mark public + incremental
        if let notePath = path {
            try publishSingleNote(notePath: notePath, vault: vault, vaultPath: vaultPath, generator: generator)
            return
        }

        // Preview mode: generate to temp dir and open
        if preview {
            try runPreview(vault: vault, generator: generator)
            return
        }

        // Normal publish (incremental or force)
        let outputPath = (vaultPath as NSString).appendingPathComponent("_site")
        let result: GenerationResult
        var manifest: PublishManifest

        if force {
            let genResult = try generator.generate(to: outputPath)
            result = genResult
            // Build fresh manifest from current public notes
            manifest = PublishManifest()
            let allNotes = try vault.allNotes()
            let publicNotes = allNotes.filter { $0.isPublic && !$0.draft }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            for note in publicNotes {
                manifest.entries[note.relativePath] = PublishManifest.ManifestEntry(
                    contentHash: PublishManifest.contentHash(for: note),
                    slug: note.slug ?? makeSlug(from: note.title),
                    collection: note.collection,
                    generatedAt: formatter.string(from: Date())
                )
            }
        } else {
            let existing = (try? PublishManifest.load(from: vaultPath)) ?? PublishManifest()
            let incremental = try generator.generateIncremental(to: outputPath, manifest: existing)
            result = incremental.result
            manifest = incremental.manifest
        }

        try manifest.save(to: vaultPath)

        if outputOption.json {
            try printJSON(PublishOutput(generated: result.generated, skipped: result.skipped, errors: result.errors))
        } else {
            print("Published: \(result.generated) generated, \(result.skipped) skipped, \(result.errors) errors")
        }

        // Git commit + push
        try gitCommitAndPush(vaultPath: vaultPath, message: "publish: update site")
    }

    // MARK: - Single Note

    private func publishSingleNote(notePath: String, vault: Vault, vaultPath: String, generator: SiteGenerator) throws {
        let filePath = (vaultPath as NSString).appendingPathComponent(notePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("Note not found: \(notePath)")
            throw ExitCode.failure
        }

        // Update frontmatter to set public: true
        try setFrontmatterPublic(filePath: filePath, isPublic: true)

        // Run incremental publish
        let outputPath = (vaultPath as NSString).appendingPathComponent("_site")
        let existing = (try? PublishManifest.load(from: vaultPath)) ?? PublishManifest()
        let incremental = try generator.generateIncremental(to: outputPath, manifest: existing)
        try incremental.manifest.save(to: vaultPath)

        if outputOption.json {
            try printJSON(PublishOutput(generated: incremental.result.generated, skipped: incremental.result.skipped, errors: incremental.result.errors))
        } else {
            print("Marked \(notePath) as public")
            print("Published: \(incremental.result.generated) generated, \(incremental.result.skipped) skipped, \(incremental.result.errors) errors")
        }

        try gitCommitAndPush(vaultPath: vaultPath, message: "publish: \(notePath)")
    }

    // MARK: - Preview

    private func runPreview(vault: Vault, generator: SiteGenerator) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maho-preview-\(UUID().uuidString)").path
        let result = try generator.generate(to: tempDir)

        if outputOption.json {
            try printJSON(PreviewOutput(path: tempDir, generated: result.generated))
        } else {
            print("Preview generated at: \(tempDir)")
            print("\(result.generated) pages generated")
        }

        #if os(macOS)
        let indexPath = (tempDir as NSString).appendingPathComponent("index.html")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [indexPath]
        try process.run()
        #endif
    }

    // MARK: - Helpers

    private func loadSiteConfig(vaultPath: String) throws -> SiteConfig {
        let config = Config(vaultPath: vaultPath)
        let vaultConfig = try config.loadVaultConfig()
        let site = vaultConfig["site"] as? [String: Any] ?? [:]
        let author = vaultConfig["author"] as? [String: Any] ?? [:]
        return SiteConfig(
            title: site["title"] as? String ?? vaultConfig["title"] as? String ?? "Maho Notes",
            domain: site["domain"] as? String ?? vaultConfig["domain"] as? String ?? "",
            author: author["name"] as? String ?? ""
        )
    }
}

// MARK: - Shared Helpers (delegates to MahoNotesKit)

#if os(macOS)
func gitCommitAndPush(vaultPath: String, message: String) throws {
    let fm = FileManager.default
    let isGitRepo = fm.fileExists(atPath: (vaultPath as NSString).appendingPathComponent(".git"))
    guard isGitRepo else { return }

    try runGit(["add", "-A"], in: vaultPath, label: "stage")
    // Check if there are staged changes
    let status = try runGitCapture(["diff", "--cached", "--quiet"], in: vaultPath)
    guard status != 0 else { return }  // nothing to commit

    try runGit(["commit", "-m", message], in: vaultPath, label: "commit")

    // Push if remote exists
    let remote = try? runGit(["remote", "get-url", "origin"], in: vaultPath, label: "check remote")
    if let remote, !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: vaultPath, label: "branch")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["push", "origin", branch], in: vaultPath, label: "push")
    }
}
#else
func gitCommitAndPush(vaultPath: String, message: String) throws {
    // No git on non-macOS
}
#endif

// MARK: - JSON Output Types

struct PublishOutput: Codable {
    let generated: Int
    let skipped: Int
    let errors: Int
}

struct PreviewOutput: Codable {
    let path: String
    let generated: Int
}
