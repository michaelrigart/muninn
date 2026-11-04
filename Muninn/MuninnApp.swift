import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var recorder: RecordingController?
    static weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.launchedAsLoginItem else { return }
        DispatchQueue.main.async { Self.model?.openMeetingsRequest += 1 }
    }

    /// `hasVisibleWindows` is not trusted: a floating panel such as the recording pill may count as a window, so a Dock click would open nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasWindow = sender.windows.contains { !($0 is NSPanel) && $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
        if !hasWindow { Self.model?.openMeetingsRequest += 1 }
        return true
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
        AppDelegate.model = model
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
                    Image("MuninnMenuBar")
                        .accessibilityLabel("Muninn")
                }
            }
            .modifier(WindowOpener(model: model))
        }
        .menuBarExtraStyle(.menu)

        Window("Meetings", id: "meetings") {
            MainWindow()
                .environmentObject(model)
        }
        .defaultLaunchBehavior(.suppressed)

        Window("Live transcript", id: "live-transcript") {
            LiveTranscriptWindow()
                .environmentObject(model)
                .environmentObject(recorder)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 420, height: 480)

        Window("Activity", id: "activity") {
            ActivityWindow()
                .environmentObject(model)
                .environmentObject(model.activity)
                .frame(minWidth: 560, minHeight: 360)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 760, height: 520)
        .commands { ActivityCommands() }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
