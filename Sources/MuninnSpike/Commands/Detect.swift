import ArgumentParser
import Foundation
import MuninnAudio

struct Detect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print call start and end events for the watch list.")

    @Option(help: "How long to watch.")
    var seconds = 60

    func run() async throws {
        let watchList = Spike.settings().watchList
        print("Watching \(watchList.count) entries for \(seconds) s: \(watchList.joined(separator: ", "))")
        let detector = CallDetector(listing: CoreAudioProcessList(), watchList: { watchList })
        let start = Date()
        let stopper = Task {
            try? await Task.sleep(for: .seconds(seconds))
            detector.stop()
        }
        detector.start()
        for await event in detector.events {
            let at = String(format: "%6.1f s", Date().timeIntervalSince(start))
            switch event {
            case .started(let bundleID, let pid): print("\(at)  started  \(bundleID)  pid \(pid)")
            case .ended(let bundleID): print("\(at)  ended    \(bundleID)")
            }
        }
        stopper.cancel()
        print("Done.")
    }
}
