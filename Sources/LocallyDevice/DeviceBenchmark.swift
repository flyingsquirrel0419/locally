import Foundation
import LocallyCore

#if canImport(Metal) && !targetEnvironment(simulator)
import Metal
#endif

/// Raw measured results from the device benchmark. No fabricated numbers:
/// metrics that could not be measured stay nil.
public struct BenchmarkResult: Codable, Sendable, Hashable {
    public var cpuGflops: Double?
    public var memoryCopyGBps: Double?
    public var metalGflops: Double?
    public var duration: TimeInterval
    public var cancelled: Bool
    /// True when the hard deadline cut the run short and some stages went
    /// unmeasured — results are partial but real.
    public var truncated: Bool

    public init(
        cpuGflops: Double? = nil,
        memoryCopyGBps: Double? = nil,
        metalGflops: Double? = nil,
        duration: TimeInterval = 0,
        cancelled: Bool = false,
        truncated: Bool = false
    ) {
        self.cpuGflops = cpuGflops
        self.memoryCopyGBps = memoryCopyGBps
        self.metalGflops = metalGflops
        self.duration = duration
        self.cancelled = cancelled
        self.truncated = truncated
    }
}

/// Clock abstraction so tests can inject a fast-forwarded clock and prove
/// the deadline logic without waiting real seconds.
protocol BenchmarkClock: Sendable {
    var now: ContinuousClock.Instant { get }
}

struct SystemBenchmarkClock: BenchmarkClock {
    var now: ContinuousClock.Instant { ContinuousClock.now }
}

/// Time-boxed, cancellable benchmark. Total wall time is kept under
/// `timeBudget`: every stage shares one deadline, checks the clock at fine
/// granularity (between calibrated sub-chunks, not only between full
/// iterations), and sizes its chunks from a quick calibration so a single
/// chunk cannot overrun the deadline by more than a few milliseconds on any
/// device. Setup (buffer allocation, Metal pipeline creation) counts
/// against the budget. Metal is skipped on the simulator, where it is
/// CPU-emulated and a single dispatch can take seconds.
public struct DeviceBenchmark: Sendable {
    /// Hard wall-clock cap for the whole benchmark.
    public var timeBudget: TimeInterval

    public init(timeBudget: TimeInterval = 4.5) {
        self.timeBudget = timeBudget
    }

    public func run() async -> BenchmarkResult {
        await run(clock: SystemBenchmarkClock())
    }

    func run(clock: some BenchmarkClock) async -> BenchmarkResult {
        let start = clock.now
        let deadline = start + .milliseconds(Int(timeBudget * 1000))

        var result = BenchmarkResult()
        var remainingStages = 3

        if !Task.isCancelled, clock.now < deadline {
            result.cpuGflops = await cpuMatmulGFLOPS(deadline: deadline, clock: clock)
            remainingStages -= 1
        }
        if !Task.isCancelled, clock.now < deadline {
            result.memoryCopyGBps = memoryCopyThroughputGBps(deadline: deadline, clock: clock)
            remainingStages -= 1
        }
        if !Task.isCancelled, clock.now < deadline {
            result.metalGflops = metalComputeGFLOPS(deadline: deadline, clock: clock)
            remainingStages -= 1
        }

        result.cancelled = Task.isCancelled
        result.truncated = remainingStages > 0 && !result.cancelled
        result.duration = start.duration(to: clock.now).timeInterval
        return result
    }

    // MARK: - CPU matmul

    /// Float32 matmul (n=192) repeated within the shared deadline. The
    /// warmup matmul doubles as calibration: its cost decides how many rows
    /// run between clock checks (~4ms chunks), so even on a very slow core a
    /// single chunk cannot overrun the deadline by more than milliseconds.
    func cpuMatmulGFLOPS(deadline: ContinuousClock.Instant,
                         clock: some BenchmarkClock) async -> Double? {
        let n = 192
        let count = n * n
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        var c = [Float](repeating: 0, count: count)
        for i in 0..<count {
            a[i] = Float((i & 63) + 1) * 0.03125
            b[i] = Float((i & 31) + 1) * 0.0625
        }

        let warmStart = clock.now
        matmulRows(a: a, b: b, c: &c, n: n, from: 0, count: n)
        if Task.isCancelled { return nil }
        let perMatmul = warmStart.duration(to: clock.now).timeInterval
        let perRow = perMatmul > 0 ? perMatmul / Double(n) : 0
        let rowsPerChunk = perRow > 0 ? max(1, Int(0.004 / perRow)) : n

        let start = clock.now
        let stageCap = start + .milliseconds(1500)
        let cap = stageCap < deadline ? stageCap : deadline

        let flopsPerMatmul = 2.0 * Double(n) * Double(n) * Double(n)
        var matmuls = 0
        var row = 0
        var chunks = 0
        while clock.now < cap && !Task.isCancelled {
            let rows = min(rowsPerChunk, n - row)
            matmulRows(a: a, b: b, c: &c, n: n, from: row, count: rows)
            row += rows
            if row >= n {
                matmuls += 1
                row = 0
            }
            chunks += 1
            if chunks % 16 == 0 { await Task.yield() }
        }
        guard matmuls > 0, !Task.isCancelled else { return nil }
        let elapsed = start.duration(to: clock.now).timeInterval
        guard elapsed > 0 else { return nil }
        return flopsPerMatmul * Double(matmuls) / elapsed / 1e9
    }

    private func matmulRows(a: [Float], b: [Float], c: inout [Float],
                            n: Int, from: Int, count: Int) {
        // i-k-j loop order for cache-friendly access of b and c rows.
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                c.withUnsafeMutableBufferPointer { pc in
                    for i in from..<(from + count) {
                        let aRow = pa.baseAddress! + i * n
                        let cRow = pc.baseAddress! + i * n
                        for k in 0..<n {
                            let aik = aRow[k]
                            let bRow = pb.baseAddress! + k * n
                            for j in 0..<n {
                                cRow[j] += aik * bRow[j]
                            }
                        }
                    }
                }
            }
        }
        // Prevent the optimizer from eliminating the loop entirely.
        if c[0] == .infinity { print(c[n - 1]) }
    }

    // MARK: - Memory copy

    /// memcpy-style throughput over a 64 MB buffer within the shared
    /// deadline. One full copy calibrates the chunk size (~10ms each);
    /// partial copies still count toward the byte total, so the clock is
    /// checked between ~10ms units of work.
    func memoryCopyThroughputGBps(deadline: ContinuousClock.Instant,
                                  clock: some BenchmarkClock) -> Double? {
        let fullBytes = 64 * 1024 * 1024
        let src = UnsafeMutableRawBufferPointer.allocate(byteCount: fullBytes, alignment: 4096)
        let dst = UnsafeMutableRawBufferPointer.allocate(byteCount: fullBytes, alignment: 4096)
        defer {
            src.deallocate()
            dst.deallocate()
        }
        src.initializeMemory(as: UInt8.self, repeating: 0x5A)
        dst.initializeMemory(as: UInt8.self, repeating: 0)

        let start = clock.now
        let stageCap = start + .milliseconds(1000)
        let cap = stageCap < deadline ? stageCap : deadline

        // Calibration copy (also the first measured bytes).
        dst.copyMemory(from: UnsafeRawBufferPointer(src))
        let calElapsed = start.duration(to: clock.now).timeInterval
        guard calElapsed > 0 else { return nil }
        var bytesCopied = Double(fullBytes)
        let chunk = calElapsed > 0.010
            ? max(4096, Int(Double(fullBytes) * 0.010 / calElapsed))
            : fullBytes

        var offset = 0
        while clock.now < cap && !Task.isCancelled {
            let n = min(chunk, fullBytes - offset)
            UnsafeMutableRawBufferPointer(rebasing: dst[offset..<(offset + n)])
                .copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<(offset + n)]))
            bytesCopied += Double(n)
            offset += n
            if offset >= fullBytes { offset = 0 }
        }
        guard !Task.isCancelled else { return nil }
        let elapsed = start.duration(to: clock.now).timeInterval
        guard elapsed > 0 else { return nil }
        // Count bytes read + written.
        return bytesCopied * 2.0 / elapsed / 1e9
    }

    // MARK: - Metal

    /// Metal compute throughput. Skipped entirely on the simulator: Metal
    /// there is emulated on the CPU, so a number would be bogus and a single
    /// dispatch can take seconds (observed overrunning the benchmark's hard
    /// deadline in CI). Reports nil ("not measured") instead.
    func metalComputeGFLOPS(deadline: ContinuousClock.Instant,
                            clock: some BenchmarkClock) -> Double? {
        #if canImport(Metal) && !targetEnvironment(simulator)
        guard clock.now < deadline, !Task.isCancelled else { return nil }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void bench(device float *out, constant float &x [[buffer(1)]],
                          uint gid [[thread_position_in_grid]]) {
            float v = x + gid * 1e-7f;
            for (int i = 0; i < 1024; i++) { v = fma(v, 1.000001f, 1e-6f); }
            out[gid] = v;
        }
        """
        // Setup (shader compile, pipeline, buffers) counts against the budget.
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let kernel = library.makeFunction(name: "bench"),
              let pipeline = try? device.makeComputePipelineState(function: kernel)
        else { return nil }

        // Small dispatches: 64K threads per command buffer so one
        // waitUntilCompleted cannot overrun the deadline by more than a few
        // milliseconds.
        let elementCount = 1 << 16
        guard let outBuffer = device.makeBuffer(length: elementCount * MemoryLayout<Float>.stride,
                                                options: .storageModeShared)
        else { return nil }
        var scalar: Float = 0.5
        guard let scalarBuffer = device.makeBuffer(bytes: &scalar, length: MemoryLayout<Float>.stride,
                                                   options: .storageModeShared)
        else { return nil }

        // Warmup doubles as calibration for the batch size (~20ms of GPU
        // work between clock checks).
        let calStart = clock.now
        if !encodeRun(queue: queue, pipeline: pipeline, out: outBuffer,
                      scalar: scalarBuffer, count: elementCount) { return nil }
        let calElapsed = calStart.duration(to: clock.now).timeInterval
        guard calElapsed > 0 else { return nil }
        let batch = max(1, Int(0.020 / calElapsed))

        let stageCap = calStart + .milliseconds(1500)
        let cap = stageCap < deadline ? stageCap : deadline
        var iterations = 1 // the warmup dispatch
        while clock.now < cap && !Task.isCancelled {
            for _ in 0..<batch {
                guard encodeRun(queue: queue, pipeline: pipeline, out: outBuffer,
                                scalar: scalarBuffer, count: elementCount) else { break }
                iterations += 1
            }
        }
        guard iterations > 0, !Task.isCancelled else { return nil }
        let elapsed = calStart.duration(to: clock.now).timeInterval
        guard elapsed > 0 else { return nil }
        // 2 FLOP per fma iteration * 1024 inner * elementCount threads * iterations
        let flops = 2.0 * 1024.0 * Double(elementCount) * Double(iterations)
        return flops / elapsed / 1e9
        #else
        return nil
        #endif
    }

    #if canImport(Metal) && !targetEnvironment(simulator)
    private func encodeRun(queue: MTLCommandQueue, pipeline: MTLComputePipelineState,
                           out: MTLBuffer, scalar: MTLBuffer, count: Int) -> Bool {
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(out, offset: 0, index: 0)
        encoder.setBuffer(scalar, offset: 0, index: 1)
        let width = pipeline.threadExecutionWidth
        let threads = MTLSize(width: count, height: 1, depth: 1)
        let perGroup = MTLSize(width: width, height: 1, depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: perGroup)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        return command.status == .completed
    }
    #endif
}

private extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
