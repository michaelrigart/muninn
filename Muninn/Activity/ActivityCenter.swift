import AppKit
import AVFoundation
import MuninnCore
import UserNotifications

/// Owns the Activity log and publishes its entries. Every writer records through `log`, whatever thread it is on,
/// and reaches `entries` through the log's observer.
@MainActor
final class ActivityCenter: ObservableObject {
    @Published private(set) var entries: [ActivityEntry] = []
    @Published var focusedEntryID: UUID?

    let log: ActivityLog
    private let dataDirectory: String
    /// Each entry's lowercased text a search looks through, built once when the entry arrives.
    private var searchText: [UUID: String] = [:]

    init(log: ActivityLog, dataDirectory: String) {
        self.log = log
        self.dataDirectory = dataDirectory
        log.setObserver { [weak self] entry in
            Task { @MainActor in self?.insert(entry) }
        }
        log.prune()
        entries = log.entries()
        for entry in entries { index(entry) }
    }

    private func index(_ entry: ActivityEntry) {
        let parts = [entry.message, entry.area.label, entry.meeting?.title, entry.details?.text(includeHost: true)]
        searchText[entry.id] = parts.compactMap { $0 }.joined(separator: "\n").lowercased()
    }

    /// True when the entry's message, area, meeting title or details contain the term, ignoring case.
    func matches(_ entry: ActivityEntry, term: String) -> Bool {
        searchText[entry.id]?.contains(term.lowercased()) ?? false
    }

    /// Writers on other threads can reach the observer out of order, so each entry goes in at its place by time, newest first.
    private func insert(_ entry: ActivityEntry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        let position = entries.firstIndex { $0.time <= entry.time } ?? entries.endIndex
        entries.insert(entry, at: position)
        index(entry)
    }

    func record(_ level: ActivityLevel, _ area: ActivityArea, _ message: String, meeting: Meeting? = nil, details: ProblemDetails? = nil) {
        log.record(ActivityEntry(time: Date(), level: level, area: area, meeting: Self.reference(meeting), message: message, details: details))
    }

    func record(_ problem: Problem, area: ActivityArea, meeting: Meeting? = nil) {
        log.record(.problem(problem, area: area, meeting: Self.reference(meeting), time: Date()))
    }

    /// Records what went wrong as a problem at the context's stage. A cancellation is not a failure and records nothing.
    func record(failure error: Error, in context: ProblemContext, meeting: Meeting? = nil) {
        guard !Self.isCancellation(error) else { return }
        record(ProblemTranslator.problem(for: error, in: context), area: context.stage.area, meeting: meeting)
    }

    /// Selects the newest entry with this title, and the meeting's when one is given. Returns false when none matches.
    @discardableResult
    func focus(problemTitle: String, meetingID: MeetingID?) -> Bool {
        let redacted = Redaction.redact(problemTitle)
        let match = entries.first { entry in
            (entry.message == problemTitle || entry.message == redacted) && (meetingID == nil || entry.meeting?.id == meetingID)
        }
        focusedEntryID = match?.id
        return match != nil
    }

    /// Records a problem the log doesn't hold and selects it. The entry is in `entries` when this returns.
    func recordAndFocus(_ problem: Problem, area: ActivityArea, meeting: ActivityMeeting?) {
        let entry = ActivityEntry.problem(problem, area: area, meeting: meeting, time: Date())
        log.record(entry)
        insert(entry.redacted())
        focusedEntryID = entry.id
    }

    func revealLogFile() {
        if FileManager.default.fileExists(atPath: log.file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log.file])
        } else {
            NSWorkspace.shared.open(log.file.deletingLastPathComponent())
        }
    }

    func diagnostics(settings: MuninnCore.Settings) async -> String {
        #if arch(arm64)
        let macClass = "Apple silicon"
        #else
        let macClass = "Intel"
        #endif
        let permissions = [
            PermissionReport(name: "Microphone", state: Self.microphoneState()),
            PermissionReport(name: "Notifications", state: await Self.notificationState()),
            PermissionReport(name: "System Audio Recording", state: "not reported by macOS"),
            PermissionReport(name: "Local Network", state: "not reported by macOS"),
        ]
        return Diagnostics.text(DiagnosticsInput(
            system: .current,
            macClass: macClass,
            settings: settings,
            permissions: permissions,
            entries: entries,
            homeDirectory: NSHomeDirectory(),
            dataDirectory: dataDirectory
        ))
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func reference(_ meeting: Meeting?) -> ActivityMeeting? {
        meeting.map { ActivityMeeting(id: $0.id, title: $0.title) }
    }

    private static func microphoneState() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked"
        @unknown default: "not reported by macOS"
        }
    }

    private static func notificationState() async -> String {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return "not available" }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized: return "allowed"
        case .denied: return "denied"
        case .provisional: return "provisional"
        case .notDetermined: return "not asked"
        default: return "not reported by macOS"
        }
    }
}
