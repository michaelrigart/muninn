import Foundation
import MuninnCore

/// The values that change several times a second. Only the pill and the live transcript window observe this, so the menu and the App scene don't re-render with it.
@MainActor
final class LiveMetrics: ObservableObject {
    static let textLimit = 4000

    @Published private(set) var elapsed: TimeInterval = 0
    /// Normalised to 0...1.
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micText = ""
    @Published private(set) var systemText = ""

    func reset() {
        elapsed = 0
        micLevel = 0
        systemLevel = 0
        micText = ""
        systemText = ""
    }

    func update(elapsed: TimeInterval, micLevel: Float, systemLevel: Float) {
        if elapsed != self.elapsed { self.elapsed = elapsed }
        if micLevel != self.micLevel { self.micLevel = micLevel }
        if systemLevel != self.systemLevel { self.systemLevel = systemLevel }
    }

    /// Each update carries the track's whole text so far; the window shows its tail so layout stays bounded.
    func setText(_ text: String, for track: Track) {
        let shown = text.count > Self.textLimit ? "… " + text.suffix(Self.textLimit) : text
        switch track {
        case .mic: if shown != micText { micText = shown }
        case .system: if shown != systemText { systemText = shown }
        }
    }
}
