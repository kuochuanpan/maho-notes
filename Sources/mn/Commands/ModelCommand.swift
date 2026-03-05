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
                    size: model.approximateSize,
                    downloaded: Self.isDownloaded(model)
                )
            }

            if outputOption.json {
                try printJSON(models)
            } else {
                let header = String(format: "%-12s %-25s %5s %10s %s", "NAME", "DISPLAY NAME", "DIM", "SIZE", "STATUS")
                print(header)
                print(String(repeating: "-", count: 72))
                for m in models {
                    let status = m.downloaded ? "downloaded" : "not downloaded"
                    let line = String(format: "%-12s %-25s %5d %10s %s", (m.name as NSString).utf8String!, (m.displayName as NSString).utf8String!, m.dimensions, (m.size as NSString).utf8String!, (status as NSString).utf8String!)
                    print(line)
                }
            }
        }

        static func isDownloaded(_ model: EmbeddingModel) -> Bool {
            modelCachePath(model) != nil
        }

        static func modelCachePath(_ model: EmbeddingModel) -> String? {
            let hfId = model.huggingFaceId
            let dirName = "models--" + hfId.replacingOccurrences(of: "/", with: "--")
            let basePath = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/huggingface/\(dirName)")
            return FileManager.default.fileExists(atPath: basePath) ? basePath : nil
        }
    }

    // MARK: - Download

    struct DownloadSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download",
            abstract: "Pre-download an embedding model"
        )

        @Argument(help: "Model name (minilm, e5-small, bge-m3)")
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
                print("Downloading '\(model.displayName)' (\(model.approximateSize))...")
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

        @Argument(help: "Model name (minilm, e5-small, bge-m3)")
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
