import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(movableByBackground: Bool) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = movableByBackground
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onContentSizeChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }
}

/// Hosts a SwiftUI view in a floating, non-activating panel that follows its content's size. The panel is
/// placed once per showing, on the screen holding the mouse pointer, and keeps its top-left corner when the content resizes.
@MainActor
final class PanelHost<Content: View> {
    private let panel: FloatingPanel
    private let hosting: FirstMouseHostingView<Content>
    private let initialTopLeft: (NSSize, NSRect) -> NSPoint
    private let resetsOnHide: Bool
    private var placed = false

    init(rootView: Content, movableByBackground: Bool, resetsOnHide: Bool, initialTopLeft: @escaping (NSSize, NSRect) -> NSPoint) {
        panel = FloatingPanel(movableByBackground: movableByBackground)
        hosting = FirstMouseHostingView(rootView: rootView)
        self.initialTopLeft = initialTopLeft
        self.resetsOnHide = resetsOnHide
        panel.contentView = hosting
        hosting.onContentSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.fit() }
        }
    }

    func show() {
        fit()
        if !panel.isVisible { panel.orderFrontRegardless() }
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if resetsOnHide { placed = false }
    }

    private func fit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        if placed, panel.contentRect(forFrameRect: panel.frame).size == size { return }
        let topLeft: NSPoint
        if placed {
            topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        } else {
            topLeft = initialTopLeft(size, Self.pointerScreenFrame())
        }
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(topLeft)
        placed = true
    }

    private static func pointerScreenFrame() -> NSRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

@MainActor
final class CallPromptPanel {
    private let host: PanelHost<CallPromptView>

    init(controller: RecordingController) {
        host = PanelHost(
            rootView: CallPromptView(controller: controller),
            movableByBackground: false,
            resetsOnHide: true
        ) { size, screen in
            NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - 16)
        }
    }

    func show() { host.show() }
    func hide() { host.hide() }
}

struct CallPromptView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch controller.state {
            case .offering(let call):
                header("phone.fill", "Call in \(call.appName)", "Record this call?")
                HStack {
                    Button("Record") { controller.record() }
                        .buttonStyle(.borderedProminent)
                    Button("Not this one") { controller.decline() }
                }
            case .confirmAllAudio(let call):
                header("exclamationmark.triangle.fill", "Can't isolate \(call.appName)'s audio", "Record all system audio instead?")
                HStack {
                    Button("Record all audio") { controller.confirmAllAudio() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { controller.cancelAllAudio() }
                }
            default:
                if let notice = controller.notice {
                    header(
                        notice.kind == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                        notice.kind == .error ? "Recording problem" : "Recording warning",
                        notice.message
                    )
                    Button("Dismiss") { controller.notice = nil }
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
