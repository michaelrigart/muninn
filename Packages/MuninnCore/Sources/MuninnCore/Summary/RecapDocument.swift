import Foundation

/// A text field of the recap whose typing is saved as it happens.
public enum RecapField: Hashable, Sendable {
    case subjectTitle(Int)
    case bulletText(Int, Int)
    case actionText(Int, Int)
    case actionOwner(Int, Int)
}

/// The recap being edited. Every change is saved at once; the undo history lives on the
/// `UndoManager` the caller passes in. Structural edits are one undo step each, and a run of
/// typing in one field is one step, registered when the run ends.
public final class RecapDocument {
    public private(set) var summary: Summary
    private let save: (Summary) -> Void
    private var typingRun: (field: RecapField, start: Summary)?

    public init(summary: Summary, save: @escaping (Summary) -> Void) {
        self.summary = summary
        self.save = save
    }

    public func edit(_ actionName: String, undoManager: UndoManager?, _ change: (inout Summary) -> Void) {
        endTyping(undoManager: undoManager)
        let before = summary
        var after = before
        change(&after)
        guard after != before else { return }
        summary = after
        save(after)
        registerUndo(restoring: before, actionName: actionName, undoManager: undoManager)
    }

    public func type(_ field: RecapField, undoManager: UndoManager?, _ change: (inout Summary) -> Void) {
        if let run = typingRun, run.field != field {
            endTyping(undoManager: undoManager)
        }
        var after = summary
        change(&after)
        guard after != summary else { return }
        if typingRun == nil {
            typingRun = (field, summary)
        }
        summary = after
        save(after)
    }

    public func endTyping(undoManager: UndoManager?) {
        guard let run = typingRun else { return }
        typingRun = nil
        guard summary != run.start else { return }
        registerUndo(restoring: run.start, actionName: "Typing", undoManager: undoManager)
    }

    public func replace(with summary: Summary, undoManager: UndoManager?) {
        typingRun = nil
        undoManager?.removeAllActions(withTarget: self)
        self.summary = summary
    }

    private func registerUndo(restoring earlier: Summary, actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        registerRestore(of: earlier, actionName: actionName, undoManager: undoManager)
        undoManager.endUndoGrouping()
    }

    private func registerRestore(of earlier: Summary, actionName: String, undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { document in
            document.restore(earlier, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }

    /// Runs inside the undo manager's own group, so it registers the inverse without opening one.
    private func restore(_ earlier: Summary, actionName: String, undoManager: UndoManager) {
        let current = summary
        typingRun = nil
        summary = earlier
        save(earlier)
        registerRestore(of: current, actionName: actionName, undoManager: undoManager)
    }
}
