import AppKit

/// The one place a call app's display name is worked out, so a meeting's untitled title reads the same when it is prepared
/// and when "No event" resets it later, even if the app has quit by then.
enum AppNames {
    static func name(bundleID: String, pid: pid_t? = nil) -> String {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName { return name }
        if let pid, let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
