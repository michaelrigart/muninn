import Foundation
import Testing
@testable import MuninnCore

struct MetricsTests {
    @Test func werExact() {
        let r = WordErrorRate.compute(reference: "Hello, world again", hypothesis: "hello world again")
        #expect(r.wer == 0)
        #expect(r.referenceWords == 3)
    }

    @Test func werOneSubstitution() {
        let r = WordErrorRate.compute(reference: "a b c d", hypothesis: "a x c d")
        #expect(r.wer == 0.25)
        #expect(r.substitutions == 1)
        #expect(r.deletions == 0)
        #expect(r.insertions == 0)
    }

    @Test func werInsertionDeletion() {
        let ins = WordErrorRate.compute(reference: "a b c", hypothesis: "a b x c")
        #expect(ins.insertions == 1 && ins.deletions == 0 && ins.substitutions == 0)
        #expect(abs(ins.wer - 1.0 / 3.0) < 1e-9)
        let del = WordErrorRate.compute(reference: "a b c d", hypothesis: "a d")
        #expect(del.deletions == 2 && del.insertions == 0 && del.substitutions == 0)
        #expect(del.wer == 0.5)
    }

    @Test func werEmptyHypothesis() {
        let r = WordErrorRate.compute(reference: "a b", hypothesis: "")
        #expect(r.deletions == 2 && r.wer == 1.0)
    }

    @Test func werEmptyReference() {
        #expect(WordErrorRate.compute(reference: "", hypothesis: "").wer == 0)
        let r = WordErrorRate.compute(reference: "", hypothesis: "x y")
        #expect(r.wer == 1.0)
        #expect(r.insertions == 2)
    }

    @Test func csvHeaderAndRow() {
        let snapshot = LoadSnapshot(
            time: Date(timeIntervalSince1970: 0), pressureLevel: 2,
            freeBytes: 1_048_576 * 100, compressedBytes: 1_048_576 * 5 + 524_288,
            swapUsedBytes: 0, swapIns: 3, swapOuts: 4, cpuBusyPercent: 42.46)
        let csv = LoadReport.csv([snapshot])
        #expect(csv == """
        time,pressure,free_mb,compressed_mb,swap_used_mb,swapins,swapouts,cpu_busy
        1970-01-01T00:00:00Z,2,100.0,5.5,0.0,3,4,42.5

        """)
    }

    @Test func systemReaderReturnsPlausibleValues() {
        let reader = SystemLoadReader()
        _ = reader.snapshot()
        let s = reader.snapshot()
        #expect([1, 2, 4].contains(s.pressureLevel))
        #expect(s.cpuBusyPercent >= 0 && s.cpuBusyPercent <= 100)
        #expect(s.freeBytes > 0 || s.compressedBytes > 0)
    }

    @Test func werTieBreakPrefersSubstitution() {
        let r = WordErrorRate.compute(reference: "a b", hypothesis: "b c")
        #expect(r.substitutions == 2 && r.deletions == 0 && r.insertions == 0)
    }

    @Test func busyPercentUsesBusyOverTotalDelta() {
        let p = busyPercent(previous: CPUTicks(busy: 10, total: 100), current: CPUTicks(busy: 30, total: 200))
        #expect(p == 20)
        #expect(busyPercent(previous: CPUTicks(busy: 5, total: 50), current: CPUTicks(busy: 5, total: 50)) == 0)
    }

    @Test func failedReadsAreListed() {
        let reader = SystemLoadReader(
            vm: { nil }, swap: { nil }, pressure: { nil }, cpu: { nil })
        let s = reader.snapshot()
        #expect(s.failedReads == ["host_statistics64", "vm.swapusage",
                                  "kern.memorystatus_vm_pressure_level", "host_processor_info"])
        #expect(s.pressureLevel == 1 && s.swapUsedBytes == 0)
        let healthy = SystemLoadReader(
            vm: { VMStats(free: 1, compressed: 2, swapIns: 3, swapOuts: 4) },
            swap: { 5 }, pressure: { 2 }, cpu: { CPUTicks(busy: 1, total: 2) })
        #expect(healthy.snapshot().failedReads.isEmpty)
    }
}
