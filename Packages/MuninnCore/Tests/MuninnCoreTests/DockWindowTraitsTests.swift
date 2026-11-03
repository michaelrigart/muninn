import Testing
@testable import MuninnCore

struct DockWindowTraitsTests {
    private func window(panel: Bool = false, titled: Bool = true, visible: Bool = true, miniaturized: Bool = false) -> DockWindowTraits {
        DockWindowTraits(isPanel: panel, isTitled: titled, isVisible: visible, isMiniaturized: miniaturized)
    }

    @Test func aVisibleTitledWindowKeepsTheDockIcon() {
        #expect(showsInDock([window()]))
    }

    @Test func aMinimizedTitledWindowKeepsTheDockIcon() {
        #expect(showsInDock([window(visible: false, miniaturized: true)]))
    }

    @Test func aVisiblePanelDoesNotKeepTheDockIcon() {
        #expect(!showsInDock([window(panel: true)]))
    }

    @Test func aVisibleUntitledWindowDoesNotKeepTheDockIcon() {
        #expect(!showsInDock([window(titled: false)]))
    }

    @Test func aClosedTitledWindowDoesNotKeepTheDockIcon() {
        #expect(!showsInDock([window(visible: false)]))
    }

    @Test func noWindowsDoNotKeepTheDockIcon() {
        #expect(!showsInDock([]))
    }
}
