import MuninnCore
import SwiftUI

/// What Muninn is doing with a meeting, what it waits for and what went wrong, shown on both tabs.
struct MeetingStatusCards: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting

    var body: some View {
        VStack(spacing: 0) {
            progressCard
            if let notice = meeting.transcriptNotice {
                ProblemCard(
                    problem: notice,
                    handlers: handlers(for: notice, tryAgain: nil),
                    showInActivity: showInActivity(notice),
                    onDismiss: { model.dismissTranscriptNotice(meeting.id) }
                )
                .inset()
            }
            if let notice = meeting.engineNotice {
                ProblemCard(
                    problem: notice,
                    handlers: handlers(for: notice, tryAgain: { regenerate() }),
                    showInActivity: showInActivity(notice),
                    onDismiss: { model.dismissEngineNotice(meeting.id) }
                )
                .inset()
            }
        }
    }

    @ViewBuilder
    private var progressCard: some View {
        switch model.progress(for: meeting) {
        case .none:
            EmptyView()
        case .queued(let ahead):
            StatusCard(
                role: .waiting,
                title: "Waiting its turn",
                explanation: ahead == 0 ? "Muninn starts on it next." : ahead == 1 ? "1 meeting ahead." : "\(ahead) meetings ahead."
            )
            .inset()
        case .working(let work):
            StatusCard(
                role: .progress,
                title: work.stage.title,
                meta: work.engine.map { "\($0.displayName) · " } ?? "",
                since: work.stageStartedAt,
                steps: (work.stage.step, PipelineStage.allCases.map(\.stepLabel))
            )
            .inset()
        case .preparingSpeechModel(let preparation):
            StatusCard(
                role: .progress,
                title: "Getting the speech model ready",
                explanation: preparation.fraction.map { "\(preparation.model) · \(Int($0 * 100))%" } ?? "This can take a few minutes the first time.",
                steps: (1, PipelineStage.allCases.map(\.stepLabel)),
                progress: preparation.fraction.map(StatusCard.Progress.fraction) ?? .indeterminate
            )
            .inset()
        case .waiting(let reason):
            let problem = Problems.waiting(reason, api: model.settings.macbook.api, claudeKeyPresent: model.claudeKeyPresent)
            ProblemCard(
                problem: problem,
                role: reason.needsYou ? .attention : .waiting,
                handlers: handlers(for: problem, tryAgain: { model.process(meeting.id) })
            )
            .inset()
        case .failed(let problem):
            ProblemCard(
                problem: problem,
                handlers: handlers(for: problem, tryAgain: { model.process(meeting.id) }),
                showInActivity: showInActivity(problem)
            )
            .inset()
        }
    }

    private func handlers(for problem: Problem, tryAgain: (() -> Void)?) -> ProblemHandlers {
        var handlers = model.problemHandlers(tryAgain: tryAgain)
        handlers.write = { regenerate($0) }
        handlers.failedEngine = problem.details.engine
        handlers.disabledReason = disabledReason
        return handlers
    }

    private func regenerate(_ engine: EngineKind? = nil) {
        model.regenerate(meeting.id, engine: engine ?? meeting.requestedEngine ?? model.settings.defaultEngine)
    }

    private func showInActivity(_ problem: Problem) -> () -> Void {
        { model.showInActivity(problem, meeting: meeting.id) }
    }

    private var disabledReason: String? {
        if model.unsavedSummaries[meeting.id] != nil { return "Save your recap edits first" }
        if model.eventChangesInFlight.contains(meeting.id) { return "Wait for the event change" }
        return nil
    }
}

extension View {
    func inset() -> some View {
        padding(.horizontal, Space.m).padding(.top, Space.s)
    }
}
