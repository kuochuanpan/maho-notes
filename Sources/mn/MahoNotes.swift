import ArgumentParser

@main
struct MahoNotes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mn",
        abstract: "Maho Notes — personal knowledge base CLI",
        version: "0.1.0",
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
        ]
    )
}
