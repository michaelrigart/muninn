import MuninnCore
import SwiftUI

struct ProblemHandlers {
    var tryAgain: (() -> Void)?
    var engineSettings: (() -> Void)?
    var changeKey: (() -> Void)?
    var signInAgain: (() -> Void)?
    var recordingSettings: (() -> Void)?
    var write: ((EngineKind) -> Void)?
    var failedEngine: EngineKind?
    var disabledReason: String?
}

/// A `Problem` as a status card, with the actions its screen can run.
struct ProblemCard: View {
    let problem: Problem
    var role: StatusCard.Role?
    var compact = false
    let handlers: ProblemHandlers
    var showInActivity: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        let isProblem = problem.severity == .problem
        StatusCard(
            role: role ?? (isProblem ? .problem : .waiting),
            title: problem.title,
            explanation: problem.explanation.isEmpty ? nil : problem.explanation,
            actions: uniqueActions.compactMap(action),
            copyDetails: isProblem ? copyText : nil,
            showInActivity: isProblem ? showInActivity : nil,
            onDismiss: onDismiss,
            compact: compact
        )
    }

    private var uniqueActions: [ProblemAction] {
        var seen = Set<ProblemAction>()
        return problem.actions.filter { seen.insert($0).inserted }
    }

    private var copyText: String {
        "\(problem.title)\n\(problem.explanation)\n\n\(problem.details.text(includeHost: true))"
    }

    private func action(for action: ProblemAction) -> StatusCard.Action? {
        let reason = handlers.disabledReason
        func plain(_ run: (() -> Void)?) -> StatusCard.Action? {
            run.map { StatusCard.Action(label: action.label, run: $0, disabledReason: reason) }
        }
        switch action {
        case .tryAgain:
            return plain(handlers.tryAgain)
        case .engineSettings:
            return plain(handlers.engineSettings)
        case .changeKey:
            return plain(handlers.changeKey)
        case .signInAgain:
            return plain(handlers.signInAgain)
        case .recordingSettings:
            return plain(handlers.recordingSettings)
        case .writeWithClaude:
            return plain(handlers.write.map { write in { write(.claude) } })
        case .writeOnThisMac:
            return plain(handlers.write.map { write in { write(.macbook) } })
        case .writeWithAnotherEngine:
            guard let write = handlers.write else { return nil }
            let engines = EngineKind.allCases.filter { $0 != handlers.failedEngine }
            return StatusCard.Action(
                label: action.label,
                run: {},
                menu: engines.map { engine in (engine.displayName, { write(engine) }) },
                disabledReason: reason
            )
        }
    }
}

extension Problem {
    /// A field's validation message: a warning with a title only.
    static func notice(_ title: String) -> Problem {
        Problem(severity: .warning, title: title, explanation: "", actions: [])
    }
}
