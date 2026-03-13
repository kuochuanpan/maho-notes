import os

/// Shared loggers for MahoNotesKit.
///
/// Usage: `Log.kit.warning("something happened")`
public enum Log {
    /// General MahoNotesKit operations (vault, collection, config).
    public static let kit = Logger(subsystem: "dev.pcca.maho-notes", category: "kit")

    /// Sync operations (git, GitHub API, iCloud).
    public static let sync = Logger(subsystem: "dev.pcca.maho-notes", category: "sync")

    /// Search and indexing operations.
    public static let search = Logger(subsystem: "dev.pcca.maho-notes", category: "search")
}
