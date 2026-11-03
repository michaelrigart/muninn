import AppKit

/// Muninn is a menu bar app that shows a Dock icon (and appears in Command-Tab) only while one of its windows is open.
@MainActor
enum DockPresence {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { windowBecameMain(window) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { windowWillClose(window) }
            },
        ]
    }

    /// Opens a window from the menu or a notification: Dock icon on, app active, window in front of other apps' windows.
    static func present(_ open: () -> Void) {
        let before = Set(visibleWindows().map(ObjectIdentifier.init))
        showInDock()
        open()
        frontWindows(opened: before)
        DispatchQueue.main.async { frontWindows(opened: before) }
    }

    private static func isDocumentWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.canBecomeMain
    }

    private static func showInDock() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    private static func visibleWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter { isDocumentWindow($0) && $0.isVisible }
    }

    /// An inactive app has no key window and `activate()` can be refused while another app is in front, so the windows are ordered front by hand, keeping their order and putting the newly opened ones on top.
    private static func frontWindows(opened before: Set<ObjectIdentifier>) {
        let windows = visibleWindows()
        let existing = windows.filter { before.contains(ObjectIdentifier($0)) }
        let new = windows.filter { !before.contains(ObjectIdentifier($0)) }
        for window in existing.reversed() + new {
            window.orderFrontRegardless()
        }
    }

    private static func windowBecameMain(_ window: NSWindow) {
        guard isDocumentWindow(window) else { return }
        showInDock()
    }

    private static func windowWillClose(_ window: NSWindow) {
        guard isDocumentWindow(window) else { return }
        DispatchQueue.main.async {
            let anyOpen = NSApp.windows.contains { isDocumentWindow($0) && ($0.isVisible || $0.isMiniaturized) }
            if !anyOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
