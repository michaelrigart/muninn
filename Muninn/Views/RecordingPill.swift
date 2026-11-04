import AppKit
import MuninnAudio
import MuninnCore
import SwiftUI

@MainActor
final class RecordingPillPanel {
    private let host: PanelHost<RecordingPillView>

    init(controller: RecordingController) {
        host = PanelHost(
            rootView: RecordingPillView(controller: controller, metrics: controller.metrics),
            movableByBackground: true,
            resetsOnHide: false
        ) { size, screen in
            NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - 16)
        }
    }

    func show() { host.show() }
    func hide() { host.hide() }
}

struct RecordingPillView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var metrics: LiveMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row
            ForEach(warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .fixedSize()
    }

    /// The warnings worth reading at a glance, by title: a track that is no longer being saved, or a call track that went quiet.
    private var warnings: [String] {
        var titles: [String] = []
        if let interruption = controller.interruption, case .writeFailed = interruption {
            titles.append(Problems.recordingTrackStopped(track: interruption.track.recordingName).title)
        }
        if let warning = controller.callAudioWarning { titles.append(warning.title) }
        return titles
    }

    private var row: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(controller.isPaused ? 0.35 : 1)
            if controller.isStarting {
                ProgressView().controlSize(.small)
                Text("Starting…")
                    .foregroundStyle(.secondary)
            } else {
                Text(Self.format(metrics.elapsed))
                    .monospacedDigit()
                meter("mic.fill", level: metrics.micLevel, help: "Microphone level")
                if !controller.isConversation {
                    meter("speaker.wave.2.fill", level: metrics.systemLevel, help: "Call audio level")
                }
                if let interruption = controller.interruption {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help(Self.helpText(for: interruption))
                }
                Button {
                    controller.flag()
                } label: {
                    HStack(spacing: 2) {
                        Text("🚩")
                        if controller.flagCount > 0 {
                            Text("\(controller.flagCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Flag this moment")
            }
            Button {
                Task { await controller.stop() }
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .disabled(controller.isFinishing)
            .help("Stop recording")
        }
    }

    private func meter(_ symbol: String, level: Float, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            LevelBar(level: level)
                .frame(width: 32, height: 6)
        }
        .help(help)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// What the warning icon's tooltip says. The reasons stay in the log.
    static func helpText(for interruption: RecordingInterruption) -> String {
        let track = interruption.track == .mic ? "Microphone" : "Call audio"
        switch interruption {
        case .configurationChanged: return "\(track): audio device changed, restarting"
        case .restartFailed: return "\(track) stopped"
        case .deviceStopped: return "\(track): device stopped"
        case .writeFailed: return Problems.recordingTrackStopped(track: interruption.track.recordingName).title
        }
    }
}

private struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.green)
                    .frame(width: proxy.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
    }
}
