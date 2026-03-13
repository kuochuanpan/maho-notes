import SwiftUI
import MahoNotesKit
import UniformTypeIdentifiers

// MARK: - Drag State

/// Tracks the currently dragged item(s) for visual feedback and synchronous payload reading.
class DragState: ObservableObject {
    @Published var draggedItemId: String?   // "note:<path>" or "collection:<id>" or "notes:<path1>\t<path2>..."
    @Published var dropTargetId: String?    // id of the node being hovered

    /// Extract all note paths from the drag payload (supports single and multi).
    var draggedNotePaths: [String] {
        guard let payload = draggedItemId else { return [] }
        if payload.hasPrefix("notes:") {
            return String(payload.dropFirst(6)).components(separatedBy: "\t")
        } else if payload.hasPrefix("note:") {
            return [String(payload.dropFirst(5))]
        }
        return []
    }

    /// Whether the current drag is a note drag (single or multi).
    var isDraggingNotes: Bool {
        guard let payload = draggedItemId else { return false }
        return payload.hasPrefix("note:") || payload.hasPrefix("notes:")
    }
}

// MARK: - Directory Drop Delegate

/// Handles drops onto collection (directory) rows.
/// Reads `DragState.draggedItemId` synchronously — never uses NSItemProvider async loading.
struct DirectoryDropDelegate: DropDelegate {
    let node: FileTreeNode
    let parentId: String?              // nil for top-level
    let siblingDirIds: [String]        // sibling directory IDs under the same parent
    let dragState: DragState
    let onMoveNote: (String, String) -> Void
    let onMoveNotes: ([String], String) -> Void   // batch move
    let onMoveCollection: (String, String) -> Void
    let onReorderTopLevel: ([String]) -> Void
    let onReorderSubCollections: (String, [String]) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        dragState.dropTargetId = node.id
    }

    func dropExited(info: DropInfo) {
        if dragState.dropTargetId == node.id {
            dragState.dropTargetId = nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let payload = dragState.draggedItemId else { return false }
        if payload.hasPrefix("collection:") {
            let collId = String(payload.dropFirst(11))
            return collId != node.id && !node.id.hasPrefix(collId + "/")
        }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let payload = dragState.draggedItemId else { return false }
        defer {
            dragState.dropTargetId = nil
            dragState.draggedItemId = nil
        }

        // Handle note drops (single or multi)
        if dragState.isDraggingNotes {
            let paths = dragState.draggedNotePaths
            // Filter out notes already in this collection
            let toMove = paths.filter { (($0 as NSString).deletingLastPathComponent) != node.id }
            guard !toMove.isEmpty else { return false }
            if toMove.count == 1 {
                onMoveNote(toMove[0], node.id)
            } else {
                onMoveNotes(toMove, node.id)
            }
            return true
        }

        if payload.hasPrefix("collection:") {
            let collId = String(payload.dropFirst(11))
            guard collId != node.id, !node.id.hasPrefix(collId + "/") else { return false }

            // Same parent → reorder among siblings
            if siblingDirIds.contains(collId) {
                var ids = siblingDirIds
                guard let fromIdx = ids.firstIndex(of: collId),
                      let toIdx = ids.firstIndex(of: node.id) else { return false }
                ids.remove(at: fromIdx)
                ids.insert(collId, at: toIdx)

                if let parentId {
                    onReorderSubCollections(parentId, ids)
                } else {
                    onReorderTopLevel(ids)
                }
                return true
            }

            // Different parent → nest into this collection
            onMoveCollection(collId, node.id)
            return true
        }

        return false
    }
}

// MARK: - Note Drop Delegate

/// Handles drops onto note rows — reorder within same collection or move from another.
struct NoteDropDelegate: DropDelegate {
    let noteNode: FileTreeNode
    let parentId: String
    let allNoteChildren: [FileTreeNode]
    let dragState: DragState
    let onReorderNotes: (String, [String]) -> Void
    let onMoveNote: (String, String) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        dragState.dropTargetId = noteNode.id
    }

    func dropExited(info: DropInfo) {
        if dragState.dropTargetId == noteNode.id {
            dragState.dropTargetId = nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let payload = dragState.draggedItemId else { return false }
        return payload.hasPrefix("note:")
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let payload = dragState.draggedItemId, payload.hasPrefix("note:") else { return false }
        defer {
            dragState.dropTargetId = nil
            dragState.draggedItemId = nil
        }

        let notePath = String(payload.dropFirst(5))
        let noteDir = (notePath as NSString).deletingLastPathComponent

        if noteDir == parentId {
            // Same collection → reorder: place at target position
            var paths = allNoteChildren.compactMap { $0.note?.relativePath ?? $0.id }
            guard let fromIdx = paths.firstIndex(of: notePath),
                  let toIdx = paths.firstIndex(of: noteNode.note?.relativePath ?? noteNode.id)
            else { return false }
            paths.remove(at: fromIdx)
            let insertIdx = fromIdx < toIdx ? toIdx : toIdx
            paths.insert(notePath, at: insertIdx)
            onReorderNotes(parentId, paths)
        } else {
            // Different collection → move to this note's parent
            onMoveNote(notePath, parentId)
        }
        return true
    }
}

// MARK: - Reject Drop Delegate

/// Placed on the "Add Note" button to reject all drops.
struct RejectDropDelegate: DropDelegate {
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .cancel)
    }
    func performDrop(info: DropInfo) -> Bool { false }
}

// MARK: - Navigator View

