import MuninnCore
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = DetailTab.recap
    @State private var transcriptMode = TranscriptMode.clean

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let id = model.selectedMeetingID, let meeting = model.meetings.first(where: { $0.id == id }) {
                MeetingDetail(meeting: meeting, tab: $tab, transcriptMode: $transcriptMode)
                    .id(meeting.id)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "waveform")
                    .navigationTitle("Meetings")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}
