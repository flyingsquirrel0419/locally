import XCTest
import LocallyCore
@testable import LocallyDevice

final class SystemDeviceProfilerTests: XCTestCase {
    func testProfileIsSane() async {
        let profile = await SystemDeviceProfiler().profile()
        XCTAssertGreaterThan(profile.physicalMemory, 0)
        XCTAssertGreaterThan(profile.availableMemoryEstimate, 0)
        XCTAssertLessThanOrEqual(profile.availableMemoryEstimate, profile.physicalMemory)
        XCTAssertGreaterThan(profile.processorCount, 0)
        XCTAssertGreaterThan(profile.activeProcessorCount, 0)
        XCTAssertFalse(profile.modelIdentifier.isEmpty)
        XCTAssertFalse(profile.osVersion.isEmpty)
        if let budget = profile.recommendedMaxWorkingSet {
            XCTAssertLessThanOrEqual(budget, profile.physicalMemory)
        }
    }
}

final class MemoryBudgetTests: XCTestCase {
    func testBaselineIs55Percent() {
        let budget = MemoryBudget.safeAIBudget(physicalMemory: 8_000_000_000,
                                               availableEstimate: 8_000_000_000)
        XCTAssertEqual(budget, 4_400_000_000)
    }

    func testClampsToAvailable() {
        let budget = MemoryBudget.safeAIBudget(physicalMemory: 8_000_000_000,
                                               availableEstimate: 1_000_000_000)
        XCTAssertEqual(budget, 1_000_000_000)
    }

    func testClampsToOsProc() {
        let budget = MemoryBudget.safeAIBudget(physicalMemory: 8_000_000_000,
                                               availableEstimate: 8_000_000_000,
                                               osProcAvailable: 2_000_000_000)
        XCTAssertEqual(budget, 2_000_000_000)
    }

    func testIgnoresZeroOsProc() {
        let budget = MemoryBudget.safeAIBudget(physicalMemory: 8_000_000_000,
                                               availableEstimate: 8_000_000_000,
                                               osProcAvailable: 0)
        XCTAssertEqual(budget, 4_400_000_000)
    }
}

final class AIPerformanceIndexTests: XCTestCase {
    func testReferenceDeviceScoresAbout500() {
        let benchmark = BenchmarkResult(
            cpuGflops: AIPerformanceIndex.referenceCPUGFLOPS,
            memoryCopyGBps: AIPerformanceIndex.referenceMemoryGBps,
            metalGflops: AIPerformanceIndex.referenceMetalGFLOPS,
            duration: 3
        )
        // 8GB reference memory gives bonus exactly 1.0 (log2(9)/log2(9)),
        // so raw == 1.0 and the curve maps the reference to 500.
        let index = AIPerformanceIndex.compute(benchmark: benchmark,
                                               physicalMemory: 8_000_000_000)
        XCTAssertNotNil(index)
        XCTAssertEqual(index!.score, 500)
    }

    func testScoreNeverReaches1000ForFiniteInput() {
        let huge = BenchmarkResult(cpuGflops: 10_000, memoryCopyGBps: 5_000,
                                   metalGflops: 1_000_000, duration: 1)
        let index = AIPerformanceIndex.compute(benchmark: huge,
                                               physicalMemory: 128_000_000_000)
        XCTAssertNotNil(index)
        XCTAssertLessThan(index!.score, 1000)
        XCTAssertGreaterThan(index!.score, 500)

        let tiny = BenchmarkResult(cpuGflops: 0.001, memoryCopyGBps: 0.001,
                                   metalGflops: 0.001, duration: 1)
        let smallIndex = AIPerformanceIndex.compute(benchmark: tiny,
                                                    physicalMemory: 512_000_000)
        XCTAssertNotNil(smallIndex)
        XCTAssertGreaterThanOrEqual(smallIndex!.score, 0)
        XCTAssertLessThan(smallIndex!.score, 1000)
    }

    func testScoreIsMonotonicAndDistinguishesDeviceGenerations() {
        // 2×/4×/8× the reference on every metric must yield strictly
        // increasing, distinct scores — the bug this fixes had all three
        // pinned at 1000.
        func index(multiple: Double) -> AIPerformanceIndex {
            let benchmark = BenchmarkResult(
                cpuGflops: AIPerformanceIndex.referenceCPUGFLOPS * multiple,
                memoryCopyGBps: AIPerformanceIndex.referenceMemoryGBps * multiple,
                metalGflops: AIPerformanceIndex.referenceMetalGFLOPS * multiple,
                duration: 1)
            return AIPerformanceIndex.compute(benchmark: benchmark,
                                              physicalMemory: 8_000_000_000)!
        }
        let two = index(multiple: 2)
        let four = index(multiple: 4)
        let eight = index(multiple: 8)
        XCTAssertLessThan(two.score, four.score)
        XCTAssertLessThan(four.score, eight.score)
        XCTAssertLessThan(eight.score, 1000)
    }

    func testNilWhenNothingMeasured() {
        XCTAssertNil(AIPerformanceIndex.compute(benchmark: BenchmarkResult(),
                                                physicalMemory: 1_000_000_000))
    }

    func testWorksWithoutMetal() {
        let benchmark = BenchmarkResult(cpuGflops: 10, memoryCopyGBps: 30, duration: 1)
        let index = AIPerformanceIndex.compute(benchmark: benchmark,
                                               physicalMemory: 8_000_000_000)
        XCTAssertNotNil(index)
        XCTAssertNil(index!.metalComponent)
        XCTAssertEqual(index!.score, 500)
    }
}

final class DeviceBenchmarkTests: XCTestCase {
    func testBenchmarkStaysWithinTimeBox() async {
        let benchmark = DeviceBenchmark(timeBudget: 4.5)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await benchmark.run()
        let elapsed = start.duration(to: clock.now)

        XCTAssertLessThan(elapsed.components.seconds, 5,
                          "benchmark exceeded 5s wall time")
        #if os(Linux)
        XCTAssertNotNil(result.cpuGflops)
        XCTAssertNotNil(result.memoryCopyGBps)
        XCTAssertNil(result.metalGflops, "Metal must be absent on Linux")
        XCTAssertGreaterThan(result.cpuGflops!, 0)
        XCTAssertGreaterThan(result.memoryCopyGBps!, 0)
        #endif
        XCTAssertGreaterThan(result.duration, 0)
        XCTAssertFalse(result.cancelled)
    }

    func testBenchmarkIsCancellable() async {
        let task = Task {
            await DeviceBenchmark(timeBudget: 4.5).run()
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.cancelled)
    }

    /// A clock whose `now` jumps forward 2s per access: from the benchmark's
    /// perspective every chunk of work eats seconds of budget, as on a
    /// loaded or slow machine. The run must still return promptly (real wall
    /// time) with partial results flagged `truncated`, never overrun.
    func testBenchmarkReturnsWithinBudgetWithSlowClock() async {
        final class FastForwardClock: BenchmarkClock {
            private let tick = LockedState<ContinuousClock.Instant>(ContinuousClock.now)
            var now: ContinuousClock.Instant {
                tick.withLock { t in
                    let current = t
                    t += .seconds(2)
                    return current
                }
            }
        }
        let realStart = ContinuousClock.now
        let result = await DeviceBenchmark(timeBudget: 4.5).run(clock: FastForwardClock())
        let realElapsed = realStart.duration(to: ContinuousClock.now)

        XCTAssertLessThan(realElapsed.components.seconds, 5,
                          "benchmark with a slow environment must still return within budget")
        XCTAssertFalse(result.cancelled)
        XCTAssertTrue(result.truncated,
                      "later stages must be skipped and flagged once the deadline passes")
        XCTAssertNil(result.metalGflops)
        XCTAssertGreaterThan(result.duration, 0)
    }
}

final class ThermalMonitorTests: XCTestCase {
    func testLinuxStreamYieldsInitialState() async {
        var iterator = ThermalMonitor().states().makeAsyncIterator()
        let first = await iterator.next()
        #if os(Linux)
        XCTAssertEqual(first, .nominal)
        #else
        XCTAssertNotNil(first)
        #endif
    }
}
