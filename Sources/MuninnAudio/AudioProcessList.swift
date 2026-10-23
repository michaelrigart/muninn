import CoreAudio
import Foundation

public struct AudioProcessInfo: Hashable, Sendable {
    public var pid: pid_t
    public var bundleID: String
    public var objectID: UInt32
    public var isRunningInput: Bool
    public var isRunningOutput: Bool

    public init(pid: pid_t, bundleID: String, objectID: UInt32, isRunningInput: Bool, isRunningOutput: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.objectID = objectID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

public protocol AudioProcessListing: Sendable {
    func processes() throws -> [AudioProcessInfo]
}

public enum AudioProcessList {
    public static func objectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID
        )
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }
}

public struct CoreAudioProcessList: AudioProcessListing {
    public struct ListError: Error, Equatable {
        public var status: OSStatus
    }

    public init() {}

    public func processes() throws -> [AudioProcessInfo] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw ListError(status: status) }
        var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs)
        guard status == noErr else { throw ListError(status: status) }
        return objectIDs.compactMap(Self.info(for:))
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func info(for objectID: AudioObjectID) -> AudioProcessInfo? {
        guard
            let pid: pid_t = value(objectID, kAudioProcessPropertyPID),
            let bundle: CFString = value(objectID, kAudioProcessPropertyBundleID),
            let input: UInt32 = value(objectID, kAudioProcessPropertyIsRunningInput),
            let output: UInt32 = value(objectID, kAudioProcessPropertyIsRunningOutput)
        else { return nil }
        return AudioProcessInfo(
            pid: pid,
            bundleID: bundle as String,
            objectID: objectID,
            isRunningInput: input != 0,
            isRunningOutput: output != 0
        )
    }

    private static func value<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer) == noErr else { return nil }
        return buffer.move()
    }
}
