import AppKit
import MuninnCore
import SwiftUI

/// The transcript tab's handle on its text view, for the toolbar and the recap: find, copy all and reveal. It holds the
/// text view weakly with the layout it shows; a reveal asked for before they attach waits until they do.
@MainActor
final class TranscriptController: ObservableObject {
    @Published var following = true

    private(set) weak var textView: TranscriptNSTextView?
    private(set) var layout: TranscriptLayout?
    private var pendingReveal: Int?
    private var tint: NSRange?
    private var tintToken = 0

    func attach(_ textView: TranscriptNSTextView, layout: TranscriptLayout) {
        endTint()
        self.textView = textView
        self.layout = layout
        carryOutPendingReveal()
    }

    func detach(_ textView: TranscriptNSTextView) {
        guard self.textView === textView else { return }
        endTint()
        self.textView = nil
        layout = nil
    }

    func showFind() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(sender)
    }

    /// Copies what the view shows: speaker lines, timestamps and text.
    func copyAll() {
        guard let layout else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(layout.string, forType: .string)
    }

    /// Scrolls the segment to the centre and tints its text for 2 s.
    func reveal(segmentID: Int) {
        pendingReveal = segmentID
        carryOutPendingReveal()
    }

    func userScrolled() {
        if following { following = false }
    }

    func viewDidLayout() {
        guard pendingReveal != nil else { return }
        Task { self.carryOutPendingReveal() }
    }

    private func carryOutPendingReveal() {
        guard let id = pendingReveal, let textView, let layout, textView.window != nil,
              let clip = textView.enclosingScrollView?.contentView, clip.bounds.height > 0 else { return }
        pendingReveal = nil
        guard let index = layout.segmentIndex(forSegmentID: id) else { return }
        let segment = layout.segments[index]
        textView.centre(segment.line)
        startTint(segment.text, in: textView)
    }

    private func startTint(_ range: NSRange, in textView: TranscriptNSTextView) {
        endTint()
        guard let layoutManager = textView.layoutManager else { return }
        layoutManager.addTemporaryAttribute(.backgroundColor, value: Theme.AppKit.accentSoft, forCharacterRange: range)
        tint = range
        let token = tintToken
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard tintToken == token else { return }
            endTint()
        }
    }

    private func endTint() {
        tintToken += 1
        guard let range = tint else { return }
        tint = nil
        guard let textView, let layoutManager = textView.layoutManager,
              NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    }
}

/// The transcript as one continuous, selectable text flow: speaker lines in their colours, timestamps in the margin.
struct TranscriptTextView: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let transcript: Transcript
    let clean: CleanTranscript?
    let mode: TranscriptMode
    let controller: TranscriptController
    let onRename: (_ speaker: String, _ name: String) -> Void
    let onSeek: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TranscriptScrollView {
        let textView = TranscriptNSTextView()
        let scrollView = TranscriptScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        let coordinator = context.coordinator
        let controller = controller
        textView.onClick = { [weak coordinator] event in coordinator?.click(event) }
        scrollView.onUserScroll = { [weak controller] in controller?.userScrolled() }
        scrollView.onLayout = { [weak controller] in controller?.viewDidLayout() }
        coordinator.textView = textView
        coordinator.update(userName: model.resolvedUserName)
        return scrollView
    }

    func updateNSView(_ scrollView: TranscriptScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(userName: model.resolvedUserName)
    }

    static func dismantleNSView(_ scrollView: TranscriptScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator {
        var parent: TranscriptTextView
        weak var textView: TranscriptNSTextView?
        private var inputs: Inputs?
        private var popover: NSPopover?

        private struct Inputs: Equatable {
            let transcript: Transcript
            let clean: CleanTranscript?
            let mode: TranscriptMode
            let speakerNames: [String: String]
            let userName: String
            let flags: [Flag]
        }

        init(parent: TranscriptTextView) {
            self.parent = parent
        }

        /// Builds the text again only when what it shows changed, keeping the segment at the top where it was.
        func update(userName: String) {
            guard let textView else { return }
            let inputs = Inputs(
                transcript: parent.transcript,
                clean: parent.clean,
                mode: parent.mode,
                speakerNames: parent.meeting.speakerNames,
                userName: userName,
                flags: parent.meeting.flags
            )
            guard inputs != self.inputs else { return }
            self.inputs = inputs
            let anchor = textView.topAnchor(in: parent.controller.layout)
            let layout = TranscriptLayout.make(
                transcript: inputs.transcript,
                clean: inputs.clean,
                mode: inputs.mode,
                speakerNames: inputs.speakerNames,
                userName: inputs.userName,
                flags: inputs.flags
            )
            textView.textStorage?.setAttributedString(TranscriptStyle.text(layout, colours: SpeakerColours.indices(for: inputs.transcript)))
            textView.restore(anchor, in: layout)
            parent.controller.attach(textView, layout: layout)
        }

        func click(_ event: NSEvent) {
            guard let textView, let layout = parent.controller.layout, let offset = textView.characterIndex(at: event) else { return }
            if let line = layout.speakerLine(atOffset: offset) {
                rename(line, in: textView)
            } else if let time = layout.seekTime(atOffset: offset) {
                parent.onSeek(time)
            }
        }

        func dismantle() {
            popover?.close()
            popover = nil
            if let textView { parent.controller.detach(textView) }
        }

        private func rename(_ line: TranscriptLayout.SpeakerLine, in textView: TranscriptNSTextView) {
            popover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            let form = SpeakerRenameForm(
                name: line.name,
                initial: parent.meeting.speakerNames[line.speaker] ?? "",
                onCancel: { [weak popover] in popover?.close() },
                onSave: { [weak self, weak popover] name in
                    self?.parent.onRename(line.speaker, name)
                    popover?.close()
                }
            )
            let hosting = NSHostingController(rootView: form)
            hosting.sizingOptions = .preferredContentSize
            popover.contentViewController = hosting
            popover.show(relativeTo: textView.boundingRect(forCharacters: line.range), of: textView, preferredEdge: .maxY)
            self.popover = popover
        }
    }
}

/// Renaming a speaker; a blank name puts the default back.
struct SpeakerRenameForm: View {
    let name: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(name: String, initial: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.name = name
        self.onCancel = onCancel
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename \(name)")
                .font(.headline)
            TextField("Name", text: $draft)
                .frame(width: 200)
                .focused($focused)
                .onSubmit { onSave(draft) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

/// The scroll view around the transcript; it reports scrolling by the owner (wheel, trackpad or scroller), never
/// scrolling by the app.
final class TranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(willStartLiveScroll), name: NSScrollView.willStartLiveScrollNotification, object: self)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?()
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    @objc private func willStartLiveScroll(_ notification: Notification) {
        onUserScroll?()
    }
}

/// The transcript's text view, on TextKit 1 with non-contiguous layout so it stays lazy, and so read-along can mark
/// text with the layout manager's temporary attributes without laying it out again.
final class TranscriptNSTextView: NSTextView {
    var onClick: ((NSEvent) -> Void)?

    private let storage: NSTextStorage

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        self.storage = storage
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: Space.l, height: Space.l)
        setAccessibilityLabel("Transcript")
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// A click that selects nothing; a drag or a double-click that selects text is left alone.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard selectedRange().length == 0 else { return }
        onClick?(event)
    }

    /// Keeps the column at most the reading width plus the timestamp margin, centred.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let horizontal = max(Space.l, (newSize.width - TranscriptStyle.columnWidth) / 2)
        if textContainerInset.width != horizontal {
            textContainerInset = NSSize(width: horizontal, height: Space.l)
        }
    }

    /// The character under the event's point, or nil when the point is off any text.
    func characterIndex(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard used.contains(local) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// The characters' bounding rectangle in the view's coordinates, laying out only that range.
    func boundingRect(forCharacters range: NSRange) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    func centre(_ range: NSRange) {
        guard let clip = enclosingScrollView?.contentView else { return }
        scroll(toY: boundingRect(forCharacters: range).midY - clip.bounds.height / 2)
    }

    struct TopAnchor {
        let segmentID: Int
        let start: TimeInterval
        /// How far the segment's line starts below the top of the visible rect.
        let offset: CGFloat
    }

    /// The first segment whose line reaches the top of the visible rect, or nil when the view is not scrolled.
    func topAnchor(in layout: TranscriptLayout?) -> TopAnchor? {
        guard let layout, let layoutManager, let textContainer, window != nil,
              visibleRect.minY > 0, layoutManager.numberOfGlyphs > 0 else { return nil }
        let top = NSPoint(x: 0, y: max(0, visibleRect.minY - textContainerOrigin.y))
        let offset = layoutManager.characterIndexForGlyph(at: layoutManager.glyphIndex(for: top, in: textContainer))
        guard let segment = layout.segments.first(where: { NSMaxRange($0.line) >= offset }) else { return nil }
        return TopAnchor(segmentID: segment.segmentID, start: segment.start, offset: boundingRect(forCharacters: segment.line).minY - visibleRect.minY)
    }

    /// Puts the anchor's segment back where it was; a segment this view doesn't show is replaced by the next one.
    func restore(_ anchor: TopAnchor?, in layout: TranscriptLayout) {
        guard let anchor else { return }
        let index = layout.segmentIndex(forSegmentID: anchor.segmentID) ?? layout.segments.firstIndex { $0.start >= anchor.start }
        guard let index else { return }
        scroll(toY: boundingRect(forCharacters: layout.segments[index].line).minY - anchor.offset)
    }

    private func scroll(toY y: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        sizeToFit()
        let clip = scrollView.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size))
        clip.scroll(to: target.origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// The transcript's attributes: a 64 pt timestamp margin, speaker lines in their colours, removed words struck through.
private enum TranscriptStyle {
    static let margin: CGFloat = 64
    static let columnWidth = Theme.readingWidth + margin

    private static let readingFont = NSFont.systemFont(ofSize: 14.5)
    private static let speakerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let timestampFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let segmentParagraph = paragraph(spacingBefore: 0)
    private static let speakerParagraph = paragraph(spacingBefore: 12)

    static func text(_ layout: TranscriptLayout, colours: [String: Int]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: layout.string, attributes: [
            .font: readingFont,
            .foregroundColor: Theme.AppKit.primaryText,
            .paragraphStyle: segmentParagraph,
        ])
        let string = layout.string as NSString
        for line in layout.speakerLines {
            result.addAttribute(.paragraphStyle, value: speakerParagraph, range: string.paragraphRange(for: line.range))
            result.addAttributes([
                .font: speakerFont,
                .foregroundColor: Theme.AppKit.speaker(colours[line.speaker] ?? 0),
            ], range: line.range)
        }
        for segment in layout.segments {
            result.addAttributes([
                .font: timestampFont,
                .foregroundColor: segment.flag == nil ? Theme.AppKit.secondaryText : Theme.AppKit.attentionText,
            ], range: segment.flag.map { NSUnionRange(segment.timestamp, $0) } ?? segment.timestamp)
            for removed in segment.removed {
                result.addAttributes([
                    .foregroundColor: Theme.AppKit.secondaryText,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: removed)
            }
        }
        return result
    }

    private static func paragraph(spacingBefore: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: margin)]
        style.headIndent = margin
        style.paragraphSpacing = 6
        style.paragraphSpacingBefore = spacingBefore
        return style
    }
}
