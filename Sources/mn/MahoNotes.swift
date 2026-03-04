import ArgumentParser

@main
struct MahoNotes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mn",
        abstract: "Maho Notes — personal knowledge base CLI",
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            ShowCommand.self,
            NewCommand.self,
            SearchCommand.self,
            SyncCommand.self,
        ]
    )
}
