import MuninnCore
import SwiftUI

/// The player docked under a meeting: speaker lanes over the scrubber and the controls, or why the recording can't play.
/// Only the small views that show the time observe the clock.
struct PlayerBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: MeetingPlayer
    let meeting: Meeting
    let lanes: [PlaybackLane]
    let speakerIndices: [String: Int]

    private static let loadingReason = "The recording is still loading"

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
        }
        .background(.bar)
    }

    private var isCurrent: Bool { player.meetingID == meeting.id }
    private var isReady: Bool { isCurrent && player.state == .ready }

    @ViewBuilder
    private var content: some View {
        switch isCurrent ? player.state : .loading {
        case .unavailable:
            Text("The recording for this meeting isn't available.")
                .font(Theme.meta)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let problem):
            ProblemCard(
                problem: problem,
                compact: true,
                handlers: model.problemHandlers(tryAgain: { player.load(meeting) }),
                showInActivity: { model.showInActivity(problem, meeting: meeting.id) }
            )
        case .idle, .loading, .ready:
            controls
        }
    }

    private var controls: some View {
        VStack(spacing: Space.xs) {
            PlayerTimeline(
                clock: player.clock,
                duration: isCurrent ? player.duration : 0,
                lanes: lanes,
                speakerIndices: speakerIndices,
                flags: meeting.flags.map(\.offset),
                seek: { player.seek(to: $0) }
            )
            HStack(spacing: Space.m) {
                transport
                Spacer(minLength: Space.m)
                speedMenu
                volumeControl
                if isCurrent, player.tracks.count > 1 {
                    mixMenu
                }
            }
        }
        .disabled(!isReady)
    }

    private var transport: some View {
        let playing = isCurrent && player.isPlaying
        return HStack(spacing: Space.s) {
            iconButton("gobackward.15", label: "Back 15 seconds") { player.skip(by: -Playback.skipInterval) }
            iconButton(playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", size: 20) { player.toggle() }
            iconButton("goforward.15", label: "Forward 15 seconds") { player.skip(by: Playback.skipInterval) }
        }
    }

    private func iconButton(_ symbol: String, label: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(isReady ? label : Self.loadingReason)
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: $player.speed) {
                ForEach(Playback.speeds, id: \.self) { speed in
                    Text(Playback.speedLabel(speed)).tag(speed)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(Playback.speedLabel(player.speed))
                .font(Theme.mono)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Speed")
        .help(isReady ? "Playback speed" : Self.loadingReason)
    }

    private var volumeControl: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            Slider(value: $player.volume, in: 0...1)
                .controlSize(.small)
                .frame(width: 80)
                .accessibilityLabel("Volume")
        }
        .help(isReady ? "Volume" : Self.loadingReason)
    }

    private var mixMenu: some View {
        Menu {
            Picker("Mix", selection: $player.mix) {
                ForEach(PlaybackMix.allCases, id: \.self) { mix in
                    Text(mix.label).tag(mix)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(player.mix.label)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Mix")
        .help(isReady ? "Choose which tracks you hear" : Self.loadingReason)
    }
}

/// The lanes over the scrubber, with the elapsed and remaining time either side. While the scrubber is dragged, the
/// labels and the playhead follow the drag; the seek happens when it ends.
private struct PlayerTimeline: View {
    let clock: PlaybackClock
    let duration: TimeInterval
    let lanes: [PlaybackLane]
    let speakerIndices: [String: Int]
    let flags: [TimeInterval]
    let seek: (TimeInterval) -> Void
    @State private var dragTime: TimeInterval?

    var body: some View {
        Grid(horizontalSpacing: Space.s, verticalSpacing: Space.xs) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                SpeakerLanes(lanes: lanes, speakerIndices: speakerIndices, flags: flags, duration: duration)
                    .overlay { Playhead(clock: clock, dragTime: dragTime, duration: duration) }
                    .padding(.horizontal, Scrubber.thumbInset)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                TimeLabel(clock: clock, dragTime: dragTime, duration: duration, remaining: false)
                    .gridColumnAlignment(.trailing)
                Scrubber(clock: clock, duration: duration, dragTime: $dragTime, seek: seek)
                TimeLabel(clock: clock, dragTime: dragTime, duration: duration, remaining: true)
                    .gridColumnAlignment(.leading)
            }
        }
    }
}

private struct TimeLabel: View {
    @ObservedObject var clock: PlaybackClock
    let dragTime: TimeInterval?
    let duration: TimeInterval
    let remaining: Bool

    var body: some View {
        let time = min(max(dragTime ?? clock.time, 0), duration)
        Text(remaining ? "\u{2212}" + Timestamp.format(duration - time) : Timestamp.format(time))
            .font(Theme.mono)
            .monospacedDigit()
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(remaining ? "Remaining" : "Elapsed")
            .accessibilityValue(Timestamp.format(remaining ? duration - time : time))
    }
}

private struct Scrubber: View {
    static let thumbInset: CGFloat = 8

    @ObservedObject var clock: PlaybackClock
    let duration: TimeInterval
    @Binding var dragTime: TimeInterval?
    let seek: (TimeInterval) -> Void
    @State private var editing = false

    var body: some View {
        let upper = max(duration, 1)
        let shown = min(max(dragTime ?? clock.time, 0), upper)
        Slider(
            value: Binding(
                get: { shown },
                set: { value in
                    guard value.isFinite else { return }
                    if editing { dragTime = value } else { seek(value) }
                }
            ),
            in: 0...upper,
            onEditingChanged: { began in
                editing = began
                guard !began, let time = dragTime else { return }
                dragTime = nil
                seek(time)
            }
        )
        .controlSize(.small)
        .accessibilityLabel("Position")
        .accessibilityValue(Timestamp.format(shown))
    }
}

private struct Playhead: View {
    @ObservedObject var clock: PlaybackClock
    let dragTime: TimeInterval?
    let duration: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let fraction = duration > 0 ? min(max((dragTime ?? clock.time) / duration, 0), 1) : 0
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
                .offset(x: fraction * max(geometry.size.width - 2, 0))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One 6-pt row per lane, each span in its speaker's colour, with the flags as ticks across all rows.
private struct SpeakerLanes: View {
    static let rowHeight: CGFloat = 6
    static let rowGap: CGFloat = 2

    let lanes: [PlaybackLane]
    let speakerIndices: [String: Int]
    let flags: [TimeInterval]
    let duration: TimeInterval

    var body: some View {
        let rows = max(lanes.count, 1)
        Canvas { context, size in
            for row in 0..<rows {
                let rect = CGRect(x: 0, y: CGFloat(row) * (Self.rowHeight + Self.rowGap), width: size.width, height: Self.rowHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Theme.neutralSoft))
            }
            guard duration > 0 else { return }
            let scale = size.width / duration
            for (row, lane) in lanes.enumerated() {
                let y = CGFloat(row) * (Self.rowHeight + Self.rowGap)
                for span in lane.spans {
                    let start = min(max(span.start, 0), duration)
                    let end = min(max(span.end, start), duration)
                    let rect = CGRect(x: start * scale, y: y, width: max((end - start) * scale, 1), height: Self.rowHeight)
                    context.fill(Path(rect), with: .color(Theme.speaker(speakerIndices[span.speaker] ?? 0)))
                }
            }
            for flag in flags where flag.isFinite && flag >= 0 && flag <= duration {
                let rect = CGRect(x: flag * scale - 1, y: 0, width: 2, height: size.height)
                context.fill(Path(rect), with: .color(Theme.attentionFill))
            }
        }
        .frame(height: CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.rowGap)
        .accessibilityElement()
        .accessibilityLabel("Speakers over time")
    }
}
