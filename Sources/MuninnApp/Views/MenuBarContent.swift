import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecordingController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let notice = recorder.notice {
            Text(notice.message)
            Button("Dismiss") { recorder.notice = nil }
            Divider()
        }
        ForEach(model.settings.accounts.filter { model.signInNeeded.contains($0.id) }, id: \.id) { account in
            Button("⚠ Sign in again to \(account.displayName) (calendar)") {
                openSettings()
                NSApp.activate()
            }
            Divider()
        }
        controls
        Divider()
        Button("Show live transcript") {
            openWindow(id: "live-transcript")
            NSApp.activate(ignoringOtherApps: true)
        }
        let recent = Array(model.meetings.prefix(5))
        if !recent.isEmpty {
            Divider()
            Text("Recent meetings")
            ForEach(recent) { meeting in
                Button(meeting.title) {
                    model.selectedMeetingID = meeting.id
                    openMeetings()
                }
            }
        }
        Divider()
        Button("Open meetings…") { openMeetings() }
            .keyboardShortcut("o")
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Muninn") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .recording:
            if recorder.isStarting {
                Text("Starting…")
            } else if recorder.isFinishing {
                Text("Finishing…")
            } else {
                Text(recorder.isPaused ? "Paused" : "Recording")
                Button("Flag this moment") { recorder.flag() }
                if recorder.isPaused {
                    Button("Resume") { recorder.resume() }
                } else {
                    Button("Pause") { recorder.pause() }
                }
            }
            Button("Stop recording") { Task { await recorder.stop() } }
                .disabled(recorder.isFinishing)
        case .offering(let call):
            Button("Record call in \(call.appName)") { recorder.record() }
            Button("Not this one") { recorder.decline() }
        case .confirmAllAudio(let call):
            Button("Record all audio (can't isolate \(call.appName))") { recorder.confirmAllAudio() }
            Button("Cancel") { recorder.cancelAllAudio() }
        case .idle:
            ForEach(recorder.activeCalls, id: \.bundleID) { call in
                Button("Record call in \(call.appName)") { recorder.startCall(bundleID: call.bundleID, pid: call.pid) }
            }
            Button("Record a conversation…") { recorder.startConversation() }
        }
    }

    private func openMeetings() {
        openWindow(id: "meetings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The menu content isn't alive while the menu is closed, so the menu bar label opens the Meetings window on request.
struct MeetingsOpener: ViewModifier {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: model.openMeetingsRequest) {
            openWindow(id: "meetings")
            NSApp.activate()
        }
    }
}
