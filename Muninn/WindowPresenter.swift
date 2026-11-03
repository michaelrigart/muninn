import AppKit

/// Opens a window in front of other apps' windows. An inactive app has no key window and `activate()` can be refused while another app is in front, so the windows are ordered front by hand: those already open keep their order and the newly opened ones go on top.
@MainActor
enum WindowPresenter {
    static func present(_ open: () -> Void) {
        let before = Set(visibleWindows().map(ObjectIdentifier.init))
        open()
        NSApp.activate()
        frontWindows(opened: before)
        DispatchQueue.main.async {
            NSApp.activate()
            frontWindows(opened: before)
        }
    }

    private static func visibleWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter { !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.isVisible }
    }

    private static func frontWindows(opened before: Set<ObjectIdentifier>) {
        let windows = visibleWindows()
        let existing = windows.filter { before.contains(ObjectIdentifier($0)) }
        let new = windows.filter { !before.contains(ObjectIdentifier($0)) }
        for window in existing.reversed() + new {
            window.orderFrontRegardless()
        }
        let target = new.last ?? NSApp.keyWindow.flatMap { windows.contains($0) ? $0 : nil } ?? existing.first
        target?.makeKeyAndOrderFront(nil)
        target?.orderFrontRegardless()
    }
}
