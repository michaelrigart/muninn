import Darwin
import Foundation

public struct LoadSnapshot: Codable, Equatable, Sendable {
    public var time: Date
    public var pressureLevel: Int
    public var freeBytes: UInt64
    public var compressedBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapIns: UInt64
    public var swapOuts: UInt64
    public var cpuBusyPercent: Double
    public var failedReads: [String]

    public init(time: Date, pressureLevel: Int, freeBytes: UInt64, compressedBytes: UInt64,
                swapUsedBytes: UInt64, swapIns: UInt64, swapOuts: UInt64, cpuBusyPercent: Double,
                failedReads: [String] = []) {
        self.time = time
        self.pressureLevel = pressureLevel
        self.freeBytes = freeBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapIns = swapIns
        self.swapOuts = swapOuts
        self.cpuBusyPercent = cpuBusyPercent
        self.failedReads = failedReads
    }
}

public protocol LoadReading: Sendable {
    func snapshot() -> LoadSnapshot
}

struct VMStats: Sendable {
    var free: UInt64
    var compressed: UInt64
    var swapIns: UInt64
    var swapOuts: UInt64
}

struct CPUTicks: Equatable, Sendable {
    var busy: UInt64
    var total: UInt64
}

func busyPercent(previous: CPUTicks, current: CPUTicks) -> Double {
    guard current.total > previous.total else { return 0 }
    let percent = Double(current.busy &- previous.busy) / Double(current.total - previous.total) * 100
    return min(max(percent, 0), 100)
}

public final class SystemLoadReader: LoadReading, @unchecked Sendable {
    private let lock = NSLock()
    private var previousTicks: CPUTicks?
    private let readVM: @Sendable () -> VMStats?
    private let readSwap: @Sendable () -> UInt64?
    private let readPressure: @Sendable () -> Int?
    private let readCPU: @Sendable () -> CPUTicks?

    public convenience init() {
        self.init(vm: { Self.vmStatistics() }, swap: { Self.swapUsed() },
                  pressure: { Self.pressureLevel() }, cpu: { Self.cpuTicks() })
    }

    init(vm: @escaping @Sendable () -> VMStats?,
         swap: @escaping @Sendable () -> UInt64?,
         pressure: @escaping @Sendable () -> Int?,
         cpu: @escaping @Sendable () -> CPUTicks?) {
        readVM = vm
        readSwap = swap
        readPressure = pressure
        readCPU = cpu
    }

    public func snapshot() -> LoadSnapshot {
        var failed: [String] = []
        let vm = readVM()
        if vm == nil { failed.append("host_statistics64") }
        let swap = readSwap()
        if swap == nil { failed.append("vm.swapusage") }
        let pressure = readPressure()
        if pressure == nil { failed.append("kern.memorystatus_vm_pressure_level") }

        lock.lock()
        let ticks = readCPU()
        var cpu = 0.0
        if let ticks {
            if let previous = previousTicks { cpu = busyPercent(previous: previous, current: ticks) }
            previousTicks = ticks
        } else {
            failed.append("host_processor_info")
        }
        lock.unlock()

        return LoadSnapshot(
            time: Date(),
            pressureLevel: pressure ?? 1,
            freeBytes: vm?.free ?? 0,
            compressedBytes: vm?.compressed ?? 0,
            swapUsedBytes: swap ?? 0,
            swapIns: vm?.swapIns ?? 0,
            swapOuts: vm?.swapOuts ?? 0,
            cpuBusyPercent: cpu,
            failedReads: failed)
    }

    private static func vmStatistics() -> VMStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        return VMStats(free: UInt64(stats.free_count) * pageSize,
                       compressed: UInt64(stats.compressor_page_count) * pageSize,
                       swapIns: stats.swapins,
                       swapOuts: stats.swapouts)
    }

    private static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    private static func pressureLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 1, 2, 4: return Int(level)
        default: return 1
        }
    }

    private static func cpuTicks() -> CPUTicks? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let user = UInt64(UInt32(bitPattern: info[cpu * stride + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[cpu * stride + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[cpu * stride + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[cpu * stride + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return CPUTicks(busy: busy, total: total)
    }
}

public enum LoadReport {
    public static func csv(_ snapshots: [LoadSnapshot]) -> String {
        var lines = ["time,pressure,free_mb,compressed_mb,swap_used_mb,swapins,swapouts,cpu_busy"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        for s in snapshots {
            lines.append([
                formatter.string(from: s.time),
                String(s.pressureLevel),
                megabytes(s.freeBytes),
                megabytes(s.compressedBytes),
                megabytes(s.swapUsedBytes),
                String(s.swapIns),
                String(s.swapOuts),
                String(format: "%.1f", s.cpuBusyPercent),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}
