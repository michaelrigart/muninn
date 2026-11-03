import Foundation
import MuninnCore
import os

public enum SystemMemoryPressure {
    private static let logger = Logger(subsystem: "be.netronix.muninn", category: "system")
    private static let logFailure: Void = logger.error("Reading kern.memorystatus_vm_pressure_level failed or returned an unknown value; assuming normal pressure")

    public static func current() -> MemoryPressureLevel {
        if let level = read() { return level }
        _ = logFailure
        return .normal
    }

    static func read() -> MemoryPressureLevel? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return nil }
        return level(fromRaw: Int(value))
    }

    static func level(fromRaw raw: Int) -> MemoryPressureLevel? {
        MemoryPressureLevel(rawValue: raw)
    }
}
