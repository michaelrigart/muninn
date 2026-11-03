import Testing
@testable import MuninnCore

@Test func bundleIdentifierIsTheAppsIdentifier() {
    #expect(AppIdentity.bundleIdentifier == "com.michaelrigart.muninn")
}
