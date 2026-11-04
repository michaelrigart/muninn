import MuninnCore
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = DetailTab.recap
    @State private var transcriptMode = TranscriptMode.clean

    private struct PlayerKey: Hashable {
        let id: MeetingID?
        let recording: Bool
    }

    private var selectedMeeting: Meeting? {
        model.selectedMeetingID.flatMap { id in model.meetings.first { $0.id == id } }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let meeting = selectedMeeting {
                MeetingDetail(meeting: meeting, tab: $tab, transcriptMode: $transcriptMode)
                    .id(meeting.id)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "waveform")
                    .navigationTitle("Meetings")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(PlaybackKeys(player: model.player))
        .task(id: PlayerKey(id: selectedMeeting?.id, recording: selectedMeeting?.status == .recording)) {
            model.player.load(selectedMeeting)
        }
        .onDisappear { model.player.stop() }
    }
}
