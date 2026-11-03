import AppKit
import MuninnCore

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
        DispatchQueue.main.async {
            NSApp.activate()
            frontWindows(opened: before)
        }
    }

    /// A panel (the call prompt) or an untitled window (the status bar) never keeps the Dock icon.
    private static func isDocumentWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
    }

    private static func traits(_ window: NSWindow) -> DockWindowTraits {
        DockWindowTraits(
            isPanel: window is NSPanel,
            isTitled: window.styleMask.contains(.titled),
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized
        )
    }

    private static func showInDock() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    /// A window that is closing can still report itself visible while it fades out, so it is left out.
    private static func syncPolicy(closing: NSWindow? = nil) {
        let open = NSApp.windows.filter { $0 !== closing }
        let policy: NSApplication.ActivationPolicy = showsInDock(open.map(traits)) ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    private static func visibleWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter { isDocumentWindow($0) && $0.isVisible }
    }

    /// An inactive app has no key window and `activate()` can be refused while another app is in front, so the windows are ordered front by hand, keeping their order and putting the newly opened ones on top. The topmost one is made key.
    private static func frontWindows(opened before: Set<ObjectIdentifier>) {
        let windows = visibleWindows()
        let existing = windows.filter { before.contains(ObjectIdentifier($0)) }
        let new = windows.filter { !before.contains(ObjectIdentifier($0)) }
        let ordered = existing.reversed() + new
        for window in ordered {
            window.orderFrontRegardless()
        }
        let target = new.last ?? NSApp.keyWindow.flatMap { isDocumentWindow($0) ? $0 : nil } ?? existing.first
        target?.makeKeyAndOrderFront(nil)
        target?.orderFrontRegardless()
    }

    private static func windowBecameMain(_ window: NSWindow) {
        guard isDocumentWindow(window) else { return }
        showInDock()
    }

    private static func windowWillClose(_ window: NSWindow) {
        guard isDocumentWindow(window) else { return }
        // Dropping to `.accessory` in the turn after a window closes is sometimes undone (found by driving minimise, restore, close); half a second later it holds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { syncPolicy(closing: window) }
    }
}
