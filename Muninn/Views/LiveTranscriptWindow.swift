import MuninnCore
import SwiftUI

struct LiveTranscriptWindow: View {
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        Group {
            if recorder.isActive {
                VStack(alignment: .leading, spacing: 14) {
                    if let status = recorder.liveStatus {
                        Label(status, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    LiveTrackSection(metrics: recorder.metrics, track: .mic, label: recorder.isConversation ? "Conversation" : "You")
                    if !recorder.isConversation {
                        LiveTrackSection(metrics: recorder.metrics, track: .system, label: "Call")
                    }
                }
                .padding(16)
            } else {
                ContentUnavailableView("Not recording", systemImage: "waveform")
            }
        }
        .frame(minWidth: 360, minHeight: 300)
    }
}

/// Observes the live metrics itself, so only the track sections re-render as text arrives.
private struct LiveTrackSection: View {
    @ObservedObject var metrics: LiveMetrics
    let track: Track
    let label: String

    var body: some View {
        let text = track == .mic ? metrics.micText : metrics.systemText
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text.isEmpty ? "Listening…" : text)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}
