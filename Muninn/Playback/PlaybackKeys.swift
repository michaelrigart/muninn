import AppKit
import MuninnCore
import SwiftUI

/// The playback keys for the window it is in: Space plays and pauses, ← and → skip 15 s, ⇧← and ⇧→ go to the previous
/// and next segment. They leave text being edited alone, and any key with ⌘, ⌥ or ⌃.
struct PlaybackKeys: NSViewRepresentable {
    let player: MeetingPlayer

    func makeNSView(context: Context) -> PlaybackKeyView {
        let view = PlaybackKeyView()
        view.player = player
        return view
    }

    func updateNSView(_ view: PlaybackKeyView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: PlaybackKeyView, coordinator: ()) {
        view.removeMonitor()
    }
}

/// Holds a local key-down monitor while it is in a window.
final class PlaybackKeyView: NSView {
    weak var player: MeetingPlayer?

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// Whether the event was a playback key this view acted on.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let player, player.state == .ready else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        let shift = modifiers.contains(.shift)

        switch event.specialKey {
        case .leftArrow?:
            if shift {
                guard let timeline = player.timeline else { return false }
                player.seek(to: timeline.previousStart(before: player.clock.time))
            } else {
                player.skip(by: -Playback.skipInterval)
            }
            return true
        case .rightArrow?:
            if shift {
                guard let next = player.timeline?.nextStart(after: player.clock.time) else { return false }
                player.seek(to: next)
            } else {
                player.skip(by: Playback.skipInterval)
            }
            return true
        default:
            guard !shift, event.charactersIgnoringModifiers == " " else { return false }
            if !event.isARepeat { player.toggle() }
            return true
        }
    }
}
