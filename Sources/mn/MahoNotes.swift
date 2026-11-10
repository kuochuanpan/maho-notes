import ArgumentParser

@main
struct MahoNotes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mn",
        abstract: "Maho Notes — personal knowledge base CLI",
        version: mnVersion,
        subcommands: [
            InitCommand.self,
            ListCommand.self,
            ShowCommand.self,
            NewCommand.self,
            WriteCommand.self,
            EditCommand.self,
            MoveCommand.self,
            DeleteCommand.self,
            OpenCommand.self,
            SearchCommand.self,
            MetaCommand.self,
            ConfigCommand.self,
            CollectionsCommand.self,
            StatsCommand.self,
            IndexCommand.self,
            SyncCommand.self,
            VaultCommand.self,
            ModelCommand.self,
            PublishCommand.self,
            UnpublishCommand.self,
            SkillCommand.self,
            MemProfileCommand.self,
        ]
    )

    /// Same flow as ArgumentParser's default `main()`, with errors routed through
    /// `report(_:)` so `--json` callers get a JSON error instead of prose.
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            report(error)
        }
    }
}
