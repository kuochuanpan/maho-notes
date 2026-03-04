import ArgumentParser
import Foundation
import MahoNotesKit
import Yams

struct MetaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meta",
        abstract: "Show or modify note frontmatter"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Relative path to the note")
    var path: String

    @Option(name: .long, help: "Set a frontmatter field (key=value)")
    var set: [String] = []

    @Option(name: .customLong("add-tag"), help: "Add a tag")
    var addTags: [String] = []

    @Option(name: .customLong("remove-tag"), help: "Remove a tag")
    var removeTags: [String] = []

    func run() throws {
        let vault = vaultOption.makeVault()
        let filePath = (vault.path as NSString).appendingPathComponent(path)

        guard FileManager.default.fileExists(atPath: filePath) else {
            print("Note not found: \(path)")
            throw ExitCode.failure
        }

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        let (yamlStr, body) = splitFrontmatter(content)

        guard let yamlStr else {
            print("No frontmatter found in: \(path)")
            throw ExitCode.failure
        }

        guard var yaml = try Yams.load(yaml: yamlStr) as? [String: Any] else {
            print("Invalid frontmatter in: \(path)")
            throw ExitCode.failure
        }

        let hasModifications = !set.isEmpty || !addTags.isEmpty || !removeTags.isEmpty

        if hasModifications {
            // Apply --set modifications
            for pair in set {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else {
                    print("Invalid --set format: \(pair) (expected key=value)")
                    throw ExitCode.failure
                }
                let key = String(parts[0])
                let value = String(parts[1])

                // Parse booleans and integers
                if value == "true" {
                    yaml[key] = true
                } else if value == "false" {
                    yaml[key] = false
                } else if let intVal = Int(value) {
                    yaml[key] = intVal
                } else {
                    yaml[key] = value
                }
            }

            // Apply tag modifications
            var tags: [String]
            if let tagArray = yaml["tags"] as? [String] {
                tags = tagArray
            } else if let tagStr = yaml["tags"] as? String {
                tags = tagStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                tags = []
            }

            for tag in addTags where !tags.contains(tag) {
                tags.append(tag)
            }
            for tag in removeTags {
                tags.removeAll { $0 == tag }
            }
            if !addTags.isEmpty || !removeTags.isEmpty {
                yaml["tags"] = tags
            }

            // Rebuild file with updated frontmatter, preserving body
            let newYaml = try Yams.dump(object: yaml, allowUnicode: true)
            let newContent = "---\n\(newYaml)---\(body)"
            try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
            print("Updated frontmatter for: \(path)")
        } else if outputOption.json {
            // Parse as Note for structured JSON output
            let note = try parseNote(at: filePath, relativeTo: vault.path)
            if let note {
                try printJSON(note)
            }
            return
        } else {
            // Just show frontmatter
            for (key, value) in yaml.sorted(by: { $0.key < $1.key }) {
                if let arr = value as? [String] {
                    print("\(key): [\(arr.joined(separator: ", "))]")
                } else {
                    print("\(key): \(value)")
                }
            }
        }
    }
}
