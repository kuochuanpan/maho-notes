import Foundation

/// Errors from vault-level operations (notes, collections, moves).
public enum VaultError: Error, LocalizedError {
    // Move operations
    case circularMove
    case destinationExists

    // Collection operations
    case invalidCollectionName
    case collectionAlreadyExists(String)

    // Note operations
    case noteNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .circularMove:
            return "Cannot move a directory into itself or its descendant."
        case .destinationExists:
            return "A directory with that name already exists at the destination."
        case .invalidCollectionName:
            return "Collection name is invalid."
        case .collectionAlreadyExists(let id):
            return "Collection '\(id)' already exists."
        case .noteNotFound(let path):
            return "Note not found: \(path)"
        }
    }
}

// Keep old names as typealiases for backward compatibility
@available(*, deprecated, renamed: "VaultError")
public typealias MoveError = VaultError
@available(*, deprecated, renamed: "VaultError")
public typealias CollectionError = VaultError
