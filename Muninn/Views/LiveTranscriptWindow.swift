import MuninnCore
import MuninnSpeech
import SwiftUI

struct LiveTranscriptWindow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        Group {
            if recorder.isActive {
                VStack(alignment: .leading, spacing: 14) {
                    if let preparation = preparingModel {
                        StatusCard(
                            role: .progress,
                            title: "Getting the speech model ready",
                            explanation: preparation.fraction.map { "\(preparation.model) · \(Int($0 * 100))%" } ?? "This can take a few minutes the first time.",
                            progress: preparation.fraction.map(StatusCard.Progress.fraction) ?? .indeterminate
                        )
                    }
                    if let status = recorder.liveStatus {
                        ProblemCard(
                            problem: status,
                            compact: true,
                            handlers: model.problemHandlers(),
                            showInActivity: { model.showInActivity(status) }
                        )
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

    /// The live model's download or load, while it runs.
    private var preparingModel: SpeechModelPreparation? {
        let name = SpeechModelID.liveModel(named: model.settings.liveModel).displayName
        return model.speechModels.first { $0.model == name }
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
