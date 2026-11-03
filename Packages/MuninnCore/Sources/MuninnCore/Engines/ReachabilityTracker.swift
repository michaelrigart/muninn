import Foundation

/// Turns the probe's repeated answers into Activity entries for the changes only.
public struct ReachabilityTracker: Sendable {
    private var thisMac: Bool?
    private var networkMac: Bool?
    private var keyReadable: Bool?

    public init() {}

    /// `thisMac` is nil when This Mac isn't used or has no usable address, and `networkMac` when the Network Mac isn't configured: neither is tracked.
    /// A signal's first answer records nothing unless it is down.
    public mutating func entries(thisMac: Bool?, networkMac: Bool?, keyReadable: Bool, api: EndpointAPI, time: Date) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []
        func record(_ previous: inout Bool?, _ now: Bool, down: String, up: String) {
            defer { previous = now }
            if now {
                if previous == false { entries.append(ActivityEntry(time: time, level: .info, area: .engines, message: up)) }
            } else if previous != false {
                entries.append(ActivityEntry(time: time, level: .warning, area: .engines, message: down))
            }
        }
        let ollama = api == .ollama
        if let thisMac {
            record(
                &self.thisMac, thisMac,
                down: Problems.thisMacServerNotRunning(api: api, claudeKeyPresent: false, waiting: true).title,
                up: ollama ? "Ollama on This Mac is answering again" : "The model server on This Mac is answering again"
            )
        }
        if let networkMac {
            record(&self.networkMac, networkMac, down: "The Network Mac isn't answering", up: "The Network Mac is answering again")
        }
        record(&self.keyReadable, keyReadable, down: Problems.keychainUnreadable().title, up: "Muninn can read its saved key again")
        return entries
    }
}
