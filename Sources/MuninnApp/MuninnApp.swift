import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var recorder: RecordingController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = Self.recorder, recorder.needsShutdown else { return .terminateNow }
        Task {
            await recorder.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// `MenuBarExtra` draws label images as templates; a non-template image keeps its colour.
@MainActor
private enum MenuBarIcon {
    static let recording: NSImage = {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        guard let symbol = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording"),
              let image = symbol.withSymbolConfiguration(configuration)
        else { return NSImage() }
        image.isTemplate = false
        return image
    }()
}

@main
struct MuninnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var recorder: RecordingController

    init() {
        SingleInstance.claim()
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let recorder = RecordingController(model: model)
        _recorder = StateObject(wrappedValue: recorder)
        AppDelegate.recorder = recorder
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(recorder)
        } label: {
            Group {
                if recorder.isActive {
                    Image(nsImage: MenuBarIcon.recording)
                } else {
                    Image(systemName: "waveform")
                }
            }
            .modifier(MeetingsOpener(model: model))
        }
        .menuBarExtraStyle(.menu)

        Window("Meetings", id: "meetings") {
            MainWindow()
                .environmentObject(model)
        }
        .defaultLaunchBehavior(.suppressed)

        Window("Live transcript", id: "live-transcript") {
            LiveTranscriptWindow()
                .environmentObject(recorder)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 420, height: 480)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
