import ArgumentParser
import Foundation
import MahoNotesKit

struct ModelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "Manage embedding models",
        subcommands: [ListSubcommand.self, DownloadSubcommand.self, RemoveSubcommand.self],
        defaultSubcommand: ListSubcommand.self
    )

    // MARK: - List

    struct ListSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List available embedding models"
        )

        @OptionGroup var outputOption: OutputOption

        func run() throws {
            let models = EmbeddingModel.allCases.map { model in
                ModelInfo(
                    name: model.rawValue,
                    displayName: model.displayName,
                    dimensions: model.dimensions,
                    size: model.downloadSize,
                    downloaded: Self.isDownloaded(model)
                )
            }

            if outputOption.json {
                try printJSON(models)
            } else {
                print("NAME          DISPLAY NAME               DIM       SIZE  STATUS")
                print(String(repeating: "-", count: 72))
                for m in models {
                    let status = m.downloaded ? "✓ downloaded" : "—"
                    let name = m.name.padding(toLength: 13, withPad: " ", startingAt: 0)
                    let display = m.displayName.padding(toLength: 25, withPad: " ", startingAt: 0)
                    print("\(name) \(display) \(String(m.dimensions).padding(toLength: 5, withPad: " ", startingAt: 0)) \(m.size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(status)")
                }
            }
        }

        static func isDownloaded(_ model: EmbeddingModel) -> Bool {
            modelCachePath(model) != nil
        }

        static func modelCachePath(_ model: EmbeddingModel) -> String? {
            let hfId = model.huggingFaceId
            // Models are cached under ~/.maho/models/{org}/{model}
            let subPath = "models/" + hfId
            let basePath = (defaultModelCacheDir as NSString).appendingPathComponent(subPath)
            if FileManager.default.fileExists(atPath: basePath) { return basePath }
            // Also check the alternate cache format: models--{org}--{model}
            let altDirName = "models--" + hfId.replacingOccurrences(of: "/", with: "--")
            let altPath = (defaultModelCacheDir as NSString).appendingPathComponent(altDirName)
            if FileManager.default.fileExists(atPath: altPath) { return altPath }
            // Legacy: check old location ~/Documents/huggingface/
            let legacyBase = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/huggingface/\(subPath)")
            if FileManager.default.fileExists(atPath: legacyBase) { return legacyBase }
            let legacyAlt = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/huggingface/\(altDirName)")
            return FileManager.default.fileExists(atPath: legacyAlt) ? legacyAlt : nil
        }
    }

    // MARK: - Download

    struct DownloadSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download",
            abstract: "Pre-download an embedding model"
        )

        @Argument(help: "Model name (minilm, e5-small, e5-large)")
        var name: String

        func run() async throws {
            guard let model = EmbeddingModel(rawValue: name) else {
                throw ValidationError("Unknown model '\(name)'. Available: \(EmbeddingModel.allCases.map(\.rawValue).joined(separator: ", "))")
            }

            if ListSubcommand.isDownloaded(model) {
                print("Model '\(model.rawValue)' is already downloaded.")
                return
            }

            if #available(macOS 15.0, *) {
                print("Downloading '\(model.displayName)' (\(model.downloadSize))...")
                let provider = SwiftEmbeddingsProvider(model: model)
                // Trigger model download by running a dummy embed
                _ = try await provider.embed("warmup")
                print("Model '\(model.rawValue)' downloaded successfully.")
            } else {
                throw ValidationError("Model download requires macOS 15+")
            }
        }
    }

    // MARK: - Remove

    struct RemoveSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Delete a cached embedding model"
        )

        @Argument(help: "Model name (minilm, e5-small, e5-large)")
        var name: String

        func run() throws {
            guard let model = EmbeddingModel(rawValue: name) else {
                throw ValidationError("Unknown model '\(name)'. Available: \(EmbeddingModel.allCases.map(\.rawValue).joined(separator: ", "))")
            }

            guard let cachePath = ListSubcommand.modelCachePath(model) else {
                print("Model '\(model.rawValue)' is not downloaded.")
                return
            }

            try FileManager.default.removeItem(atPath: cachePath)
            print("Model '\(model.rawValue)' removed.")
        }
    }
}

private struct ModelInfo: Codable {
    let name: String
    let displayName: String
    let dimensions: Int
    let size: String
    let downloaded: Bool
}
