import ArgumentParser

@main
struct MahoNotes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mn",
        abstract: "Maho Notes — personal knowledge base CLI",
        version: "0.5.0",
        subcommands: [
            InitCommand.self,
            ListCommand.self,
            ShowCommand.self,
            NewCommand.self,
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
        ]
    )
}
