#if os(iOS)
import Foundation
import Observation
import MahoNotesKit

/// Shared sheet/alert/dialog state for iPhone and iPad content views.
/// Eliminates ~30 duplicated @State variables between the two platform views.
@Observable
@MainActor final class SheetCoordinator {

    // MARK: - New Note

    var showingNewNote = false
    var newNoteTitle = ""
    var newNoteCollectionId = ""
    var newNoteFromContextMenu = false
    var noteError: String?

    // MARK: - New Collection

    var showingNewCollection = false
    var newCollectionName = ""
    var newCollectionIcon = "folder"
    var collectionError: String?

    // MARK: - Settings & Add Vault

    var showingSettings = false
    var showingAddVault = false

    // MARK: - Rename Note

    var showingRenameNote = false
    var renameNotePath = ""
    var renameNoteTitle = ""

    // MARK: - Delete Note

    var showingDeleteNote = false
    var deleteNotePath = ""
    var deleteNoteTitle = ""

    // MARK: - Rename Collection

    var showingRenameCollection = false
    var renameCollectionId = ""
    var renameCollectionName = ""

    // MARK: - Delete Collection

    var showingDeleteCollection = false
    var deleteCollectionId = ""
    var deleteCollectionName = ""
    var deleteCollectionIsTopLevel = false
    var deleteCollectionHasContents = false

    // MARK: - Change Icon

    var showingChangeIcon = false
    var changeIconCollectionId = ""
    var changeIconValue = ""

    // MARK: - Sub-collection

    var showingNewSubCollection = false
    var newSubCollectionName = ""
    var newSubCollectionParentId = ""
    var subCollectionError: String?

    nonisolated init() {}

    // MARK: - Convenience Methods

    /// Prepare and show the rename note dialog.
    func prepareRenameNote(path: String, title: String) {
        renameNotePath = path
        renameNoteTitle = title
        showingRenameNote = true
    }

    /// Prepare and show the delete note confirmation.
    func prepareDeleteNote(path: String, title: String) {
        deleteNotePath = path
        deleteNoteTitle = title
        showingDeleteNote = true
    }

    /// Prepare and show the rename collection dialog.
    func prepareRenameCollection(id: String, name: String) {
        renameCollectionId = id
        renameCollectionName = name
        showingRenameCollection = true
    }

    /// Prepare and show the delete collection confirmation.
    func prepareDeleteCollection(id: String, name: String, isTopLevel: Bool, hasContents: Bool) {
        deleteCollectionId = id
        deleteCollectionName = name
        deleteCollectionIsTopLevel = isTopLevel
        deleteCollectionHasContents = hasContents
        showingDeleteCollection = true
    }

    /// Prepare and show the new note sheet for a specific collection.
    func prepareNewNote(collectionId: String, fromContextMenu: Bool = true) {
        newNoteCollectionId = collectionId
        newNoteTitle = ""
        noteError = nil
        newNoteFromContextMenu = fromContextMenu
        showingNewNote = true
    }

    /// Prepare and show the new sub-collection dialog.
    func prepareNewSubCollection(parentId: String) {
        newSubCollectionParentId = parentId
        newSubCollectionName = ""
        subCollectionError = nil
        showingNewSubCollection = true
    }

    /// Prepare and show the change icon sheet.
    func prepareChangeIcon(collectionId: String, currentIcon: String) {
        changeIconCollectionId = collectionId
        changeIconValue = currentIcon
        showingChangeIcon = true
    }

    /// Reset new note fields after dismissal.
    func resetNewNote() {
        newNoteTitle = ""
        newNoteCollectionId = ""
        noteError = nil
        newNoteFromContextMenu = false
    }

    /// Reset new collection fields after dismissal.
    func resetNewCollection() {
        newCollectionName = ""
        newCollectionIcon = "folder"
        collectionError = nil
    }
}
#endif
