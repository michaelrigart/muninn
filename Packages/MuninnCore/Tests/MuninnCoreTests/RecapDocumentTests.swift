import Foundation
import Testing
@testable import MuninnCore

struct RecapDocumentTests {
    private final class Saves {
        var summaries: [Summary] = []
    }

    private static func summary() -> Summary {
        Summary(
            language: "en",
            subjects: [
                Subject(
                    title: "Pricing",
                    bullets: [
                        Bullet(text: "Agreed on tiers", sources: [1]),
                        Bullet(text: "Revisit in spring", sources: [2]),
                    ],
                    actions: [ActionPoint(owner: "Jan", text: "Send quote", due: nil, sources: [1])]
                ),
                Subject(title: "Hiring", bullets: [Bullet(text: "Two roles open", sources: [3])], actions: []),
            ],
            engine: .claude,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private static func make() -> (document: RecapDocument, undo: UndoManager, saves: Saves) {
        let saves = Saves()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let document = RecapDocument(summary: summary()) { saves.summaries.append($0) }
        return (document, undo, saves)
    }

    @Test func undoRestoresARemovedBullet() {
        let (document, undo, saves) = Self.make()
        document.edit("Remove bullet", undoManager: undo) { $0.subjects[0].bullets.remove(at: 0) }
        #expect(document.summary.subjects[0].bullets.count == 1)
        undo.undo()
        #expect(document.summary == Self.summary())
        #expect(saves.summaries.count == 2)
        #expect(saves.summaries.last == Self.summary())
    }

    @Test func undoRestoresARemovedAction() {
        let (document, undo, saves) = Self.make()
        document.edit("Remove action", undoManager: undo) { $0.subjects[0].actions.remove(at: 0) }
        #expect(document.summary.subjects[0].actions.isEmpty)
        undo.undo()
        #expect(document.summary == Self.summary())
        #expect(saves.summaries.last == Self.summary())
    }

    @Test func undoRestoresARemovedSubject() {
        let (document, undo, saves) = Self.make()
        document.edit("Remove subject", undoManager: undo) { $0.subjects.remove(at: 0) }
        #expect(document.summary.subjects.count == 1)
        undo.undo()
        #expect(document.summary == Self.summary())
        #expect(saves.summaries.last == Self.summary())
    }

    @Test func redoRemovesItAgain() {
        let (document, undo, saves) = Self.make()
        document.edit("Remove bullet", undoManager: undo) { $0.subjects[0].bullets.remove(at: 0) }
        let removed = document.summary
        undo.undo()
        undo.redo()
        #expect(document.summary == removed)
        #expect(saves.summaries.count == 3)
        #expect(saves.summaries.last == removed)
    }

    @Test func typingSavesEveryChangeAndUndoesAsOneStep() {
        let (document, undo, saves) = Self.make()
        for text in ["A", "Ag", "Agr"] {
            document.type(.bulletText(0, 0), undoManager: undo) { $0.subjects[0].bullets[0].text = text }
        }
        #expect(saves.summaries.count == 3)
        #expect(undo.canUndo == false)
        document.endTyping(undoManager: undo)
        #expect(undo.undoActionName == "Typing")
        undo.undo()
        #expect(document.summary == Self.summary())
        #expect(saves.summaries.last == Self.summary())
        #expect(undo.canUndo == false)
    }

    @Test func typingUndoneBeforeEndingRegistersNothing() {
        let (document, undo, _) = Self.make()
        document.type(.bulletText(0, 0), undoManager: undo) { $0.subjects[0].bullets[0].text = "x" }
        document.type(.bulletText(0, 0), undoManager: undo) { $0.subjects[0].bullets[0].text = "Agreed on tiers" }
        document.endTyping(undoManager: undo)
        #expect(undo.canUndo == false)
    }

    @Test func typingInAnotherFieldEndsTheOpenRun() {
        let (document, undo, _) = Self.make()
        document.type(.bulletText(0, 0), undoManager: undo) { $0.subjects[0].bullets[0].text = "First" }
        document.type(.subjectTitle(0), undoManager: undo) { $0.subjects[0].title = "Second" }
        #expect(undo.canUndo)
        document.endTyping(undoManager: undo)
        undo.undo()
        #expect(document.summary.subjects[0].title == "Pricing")
        #expect(document.summary.subjects[0].bullets[0].text == "First")
        undo.undo()
        #expect(document.summary == Self.summary())
    }

    @Test func structuralEditEndsTyping() {
        let (document, undo, _) = Self.make()
        document.type(.bulletText(0, 0), undoManager: undo) { $0.subjects[0].bullets[0].text = "Typed" }
        document.edit("Remove bullet", undoManager: undo) { $0.subjects[0].bullets.remove(at: 1) }
        undo.undo()
        #expect(document.summary.subjects[0].bullets.count == 2)
        #expect(document.summary.subjects[0].bullets[0].text == "Typed")
        undo.undo()
        #expect(document.summary == Self.summary())
    }

    @Test func structuralEditInsideAnEventGroupIsItsOwnStep() {
        let (document, undo, _) = Self.make()
        undo.beginUndoGrouping()
        document.type(.bulletText(0, 0), undoManager: undo) { $0.subjects[0].bullets[0].text = "Typed" }
        document.edit("Remove bullet", undoManager: undo) { $0.subjects[0].bullets.remove(at: 1) }
        undo.endUndoGrouping()
        undo.undo()
        #expect(document.summary.subjects[0].bullets.count == 2)
        #expect(document.summary.subjects[0].bullets[0].text == "Typed")
        undo.undo()
        #expect(document.summary == Self.summary())
    }

    @Test func typingEndedFirstInsideAnEventGroupIsItsOwnStep() {
        let (document, undo, _) = Self.make()
        undo.beginUndoGrouping()
        document.type(.bulletText(0, 0), undoManager: undo) { $0.subjects[0].bullets[0].text = "Typed" }
        document.endTyping(undoManager: undo)
        document.edit("Remove bullet", undoManager: undo) { $0.subjects[0].bullets.remove(at: 1) }
        undo.endUndoGrouping()
        undo.undo()
        #expect(document.summary.subjects[0].bullets.count == 2)
        #expect(document.summary.subjects[0].bullets[0].text == "Typed")
        undo.undo()
        #expect(document.summary == Self.summary())
    }

    @Test func typingAloneInsideAnEventGroupUndoesInOneStep() {
        let (document, undo, _) = Self.make()
        undo.beginUndoGrouping()
        document.type(.bulletText(0, 0), undoManager: undo) { $0.subjects[0].bullets[0].text = "Typed" }
        document.endTyping(undoManager: undo)
        undo.endUndoGrouping()
        undo.undo()
        #expect(document.summary == Self.summary())
        #expect(undo.canUndo == false)
    }

    @Test func replaceClearsHistory() {
        let (document, undo, saves) = Self.make()
        document.edit("Remove bullet", undoManager: undo) { $0.subjects[0].bullets.remove(at: 0) }
        document.edit("Add bullet", undoManager: undo) { $0.subjects[0].bullets.append(Bullet(text: "New", sources: [])) }
        undo.undo()
        #expect(undo.canUndo)
        #expect(undo.canRedo)
        let saved = saves.summaries.count
        var fresh = Self.summary()
        fresh.subjects[0].title = "Fresh"
        document.replace(with: fresh, undoManager: undo)
        #expect(undo.canUndo == false)
        #expect(undo.canRedo == false)
        #expect(document.summary == fresh)
        #expect(saves.summaries.count == saved)
    }

    @Test func replaceDropsTheOpenRun() {
        let (document, undo, _) = Self.make()
        document.type(.bulletText(0, 0), undoManager: undo) { $0.subjects[0].bullets[0].text = "Typed" }
        var fresh = Self.summary()
        fresh.subjects[0].title = "Fresh"
        document.replace(with: fresh, undoManager: undo)
        document.endTyping(undoManager: undo)
        #expect(undo.canUndo == false)
    }

    @Test func unchangedEditRegistersNothing() {
        let (document, undo, saves) = Self.make()
        document.edit("Remove bullet", undoManager: undo) { _ in }
        #expect(saves.summaries.isEmpty)
        #expect(undo.canUndo == false)
    }

    @Test func undoCarriesTheActionName() {
        let (document, undo, _) = Self.make()
        document.edit("Remove bullet", undoManager: undo) { $0.subjects[0].bullets.remove(at: 0) }
        #expect(undo.undoActionName == "Remove bullet")
        undo.undo()
        #expect(undo.redoActionName == "Remove bullet")
    }
}
