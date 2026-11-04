import AppKit
import Combine
import MuninnCore
import SwiftUI

/// The transcript tab's handle on its text view, for the toolbar, the recap and playback: find, copy all, reveal and
/// read along. It holds the text view weakly with the layout it shows; a reveal or a follow asked for before they
/// attach waits until they do.
@MainActor
final class TranscriptController: ObservableObject {
    /// The view keeps what is playing in view. Setting it scrolls there.
    @Published var following = true {
        didSet {
            guard following else { return }
            followRequested = true
            follow()
        }
    }
    /// Playback of this meeting is running; only then does a scroll by the owner stop the following.
    var isPlaying = false

    private(set) weak var textView: TranscriptNSTextView?
    private(set) var layout: TranscriptLayout?
    private var pendingReveal: Int?
    private var tint: NSRange?
    private var tintToken = 0
    private var position: ReadAlongPosition?
    private var followRequested = false
    /// The ranges that carry a temporary background now.
    private var marked: [NSRange] = []

    func attach(_ textView: TranscriptNSTextView, layout: TranscriptLayout) {
        tintToken += 1
        tint = nil
        position = nil
        marked = []
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        self.textView = textView
        self.layout = layout
        carryOutPendingReveal()
    }

    func detach(_ textView: TranscriptNSTextView) {
        guard self.textView === textView else { return }
        tintToken += 1
        tint = nil
        position = nil
        marked = []
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

    /// Marks the segment and word spoken at `time`, or nothing when `time` is nil; only a changed position redraws.
    func readAlong(at time: TimeInterval?) {
        let position = time.flatMap { layout?.position(at: $0) }
        guard position != self.position else { return }
        self.position = position
        redrawMarks()
        if isPlaying || followRequested { follow() }
    }

    func userScrolled() {
        guard isPlaying, following else { return }
        following = false
        followRequested = false
    }

    func viewDidLayout() {
        guard pendingReveal != nil || followRequested else { return }
        Task {
            self.carryOutPendingReveal()
            if self.followRequested { self.follow() }
        }
    }

    private var canScroll: Bool {
        guard let textView, textView.window != nil, let clip = textView.enclosingScrollView?.contentView else { return false }
        return clip.bounds.height > 0
    }

    private func carryOutPendingReveal() {
        guard let id = pendingReveal, let textView, let layout, canScroll else { return }
        pendingReveal = nil
        guard let index = layout.segmentIndex(forSegmentID: id) else { return }
        let segment = layout.segments[index]
        textView.centre(segment.line)
        startTint(segment.text)
    }

    /// Brings the current segment to the centre when it is outside the middle of the visible rect.
    private func follow() {
        guard following, let position, let layout, let textView, canScroll,
              layout.segments.indices.contains(position.segment) else { return }
        followRequested = false
        let segment = layout.segments[position.segment]
        textView.keepInMiddle(segment.line, focus: wordRange(position, in: layout) ?? segment.line)
    }

    private func startTint(_ range: NSRange) {
        tint = range
        tintToken += 1
        redrawMarks()
        let token = tintToken
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard tintToken == token else { return }
            tint = nil
            redrawMarks()
        }
    }

    /// Moves the temporary backgrounds: the reveal tint, then the read-along segment and word over it. Only the ranges
    /// that change are redrawn, and nothing is laid out again.
    private func redrawMarks() {
        guard let textView, let layoutManager = textView.layoutManager, let layout else { return }
        let length = textView.textStorage?.length ?? 0
        for range in marked where NSMaxRange(range) <= length {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        var marks: [(range: NSRange, colour: NSColor)] = []
        if let tint { marks.append((tint, Theme.AppKit.accentSoft)) }
        if let position, layout.segments.indices.contains(position.segment) {
            marks.append((layout.segments[position.segment].text, Theme.AppKit.accentSoft))
            if let word = wordRange(position, in: layout) { marks.append((word, Theme.AppKit.accentMid)) }
        }
        marks.removeAll { NSMaxRange($0.range) > length }
        for mark in marks {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: mark.colour, forCharacterRange: mark.range)
        }
        marked = marks.map(\.range)
    }

    private func wordRange(_ position: ReadAlongPosition, in layout: TranscriptLayout) -> NSRange? {
        guard let word = position.word, layout.segments.indices.contains(position.segment) else { return nil }
        let words = layout.segments[position.segment].words
        return words.indices.contains(word) ? words[word].range : nil
    }
}

/// "Back to 12:04", while the owner has scrolled away from what is playing; it follows playback again.
struct TranscriptFollowButton: View {
    @EnvironmentObject private var player: MeetingPlayer
    @ObservedObject var controller: TranscriptController
    let meetingID: MeetingID

    var body: some View {
        if !controller.following, player.meetingID == meetingID, player.hasStarted {
            BackToButton(clock: player.clock) { controller.following = true }
                .padding(Space.m)
        }
    }

    /// The only view here that observes the clock.
    private struct BackToButton: View {
        @ObservedObject var clock: PlaybackClock
        let action: () -> Void

        var body: some View {
            Button("Back to \(Timestamp.format(clock.time))", action: action)
                .controlSize(.large)
                .buttonStyle(.glass)
                .help("Scroll back to what is playing and follow it")
        }
    }
}

/// The transcript as one continuous, selectable text flow: speaker lines in their colours, timestamps in the margin.
struct TranscriptTextView: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: MeetingPlayer
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
        coordinator.observe(player)
        return scrollView
    }

    func updateNSView(_ scrollView: TranscriptScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.update(userName: model.resolvedUserName)
        coordinator.observe(player)
        coordinator.playerChanged()
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
        private weak var player: MeetingPlayer?
        private var clockObservation: AnyCancellable?

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
            let margin = TranscriptStyle.margin(for: layout)
            textView.columnWidth = Theme.readingWidth + margin
            textView.textStorage?.setAttributedString(TranscriptStyle.text(layout, colours: SpeakerColours.indices(for: inputs.transcript), margin: margin))
            textView.restore(anchor, in: layout)
            parent.controller.attach(textView, layout: layout)
            if let player { readAlong(at: player.clock.time) }
        }

        /// Follows the clock with a Combine sink, so a tick moves the marks without a SwiftUI update.
        func observe(_ player: MeetingPlayer) {
            guard self.player !== player else { return }
            self.player = player
            clockObservation = player.clock.$time.sink { [weak self] time in
                MainActor.assumeIsolated { self?.readAlong(at: time) }
            }
        }

        /// The player's state changed: whether it is playing this meeting, and whether read-along starts or stops.
        func playerChanged() {
            guard let player else { return }
            parent.controller.isPlaying = isCurrent && player.isPlaying
            readAlong(at: player.clock.time)
        }

        private var isCurrent: Bool {
            player?.meetingID == parent.meeting.id
        }

        private func readAlong(at time: TimeInterval) {
            let active = isCurrent && player?.hasStarted == true
            parent.controller.readAlong(at: active ? time : nil)
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
            clockObservation = nil
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
    /// The reading width plus the timestamp margin: the column is at most this wide, centred.
    var columnWidth = Theme.readingWidth + TranscriptStyle.minimumMargin {
        didSet {
            guard columnWidth != oldValue else { return }
            fitColumn(to: frame.width)
            textContainer?.size = NSSize(width: max(0, frame.width - 2 * textContainerInset.width), height: .greatestFiniteMagnitude)
        }
    }

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

    /// Sets the inset before the frame, so the container never keeps a width for the old inset.
    override func setFrameSize(_ newSize: NSSize) {
        fitColumn(to: newSize.width)
        super.setFrameSize(newSize)
    }

    private func fitColumn(to width: CGFloat) {
        let horizontal = max(Space.l, (width - columnWidth) / 2)
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

    /// Scrolls only when `focus` is outside the middle half of the visible rect: to centre `line`, or `focus` itself
    /// when the line is taller than that half.
    func keepInMiddle(_ line: NSRange, focus: NSRange) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.documentVisibleRect
        let band = visible.insetBy(dx: 0, dy: visible.height / 4)
        let focusRect = boundingRect(forCharacters: focus)
        guard focusRect.maxY <= band.minY || focusRect.minY >= band.maxY else { return }
        let lineRect = boundingRect(forCharacters: line)
        let target = lineRect.height <= band.height ? lineRect : focusRect
        scroll(toY: target.midY - clip.bounds.height / 2)
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

/// The transcript's attributes: a timestamp margin of at least 64 pt, speaker lines in their colours, removed words
/// struck through.
@MainActor
private enum TranscriptStyle {
    static let minimumMargin: CGFloat = 64
    /// The space between the widest timestamp and the text.
    static let gutter: CGFloat = 8

    private static let speakerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    /// The widest timestamp (with its flag) in the layout plus the gutter, and never less than the minimum. Timestamps
    /// are monospaced, so one of each length, flagged or not, is measured.
    static func margin(for layout: TranscriptLayout) -> CGFloat {
        let string = layout.string as NSString
        var measured = Set<Int>()
        var widest: CGFloat = 0
        for segment in layout.segments {
            let range = segment.flag.map { NSUnionRange(segment.timestamp, $0) } ?? segment.timestamp
            guard measured.insert(range.length * 2 + (segment.flag == nil ? 0 : 1)).inserted else { continue }
            widest = max(widest, string.substring(with: range).size(withAttributes: [.font: Theme.AppKit.mono]).width)
        }
        return max(minimumMargin, ceil(widest) + gutter)
    }

    static func text(_ layout: TranscriptLayout, colours: [String: Int], margin: CGFloat) -> NSAttributedString {
        let segmentParagraph = paragraph(spacingBefore: 0, margin: margin)
        let speakerParagraph = paragraph(spacingBefore: 12, margin: margin)
        let result = NSMutableAttributedString(string: layout.string, attributes: [
            .font: Theme.AppKit.reading,
            .foregroundColor: Theme.AppKit.primaryText,
            .paragraphStyle: segmentParagraph,
        ])
        let string = layout.string as NSString
        for line in layout.speakerLines {
            result.addAttribute(.paragraphStyle, value: speakerParagraph, range: string.paragraphRange(for: line.range))
            result.addAttributes([
                .font: speakerFont,
                .foregroundColor: Theme.AppKit.speaker(colours[line.speaker] ?? 0),
                .toolTip: "Rename speaker",
                .cursor: NSCursor.pointingHand,
            ], range: line.range)
        }
        for segment in layout.segments {
            result.addAttributes([
                .font: Theme.AppKit.mono,
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

    private static func paragraph(spacingBefore: CGFloat, margin: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: margin)]
        style.headIndent = margin
        style.paragraphSpacing = 6
        style.paragraphSpacingBefore = spacingBefore
        return style
    }
}
