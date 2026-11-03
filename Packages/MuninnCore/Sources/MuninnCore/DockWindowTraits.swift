/// What decides whether a window keeps Muninn in the Dock, free of AppKit so it can be tested.
public struct DockWindowTraits: Equatable, Sendable {
    public var isPanel: Bool
    public var isTitled: Bool
    public var isVisible: Bool
    public var isMiniaturized: Bool

    public init(isPanel: Bool, isTitled: Bool, isVisible: Bool, isMiniaturized: Bool) {
        self.isPanel = isPanel
        self.isTitled = isTitled
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
    }
}

public func showsInDock(_ windows: [DockWindowTraits]) -> Bool {
    windows.contains { !$0.isPanel && $0.isTitled && ($0.isVisible || $0.isMiniaturized) }
}
