import Foundation
import LocallyCore

#if canImport(Metal)
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

    public init(
        cpuGflops: Double? = nil,
        memoryCopyGBps: Double? = nil,
        metalGflops: Double? = nil,
        duration: TimeInterval = 0,
        cancelled: Bool = false
    ) {
        self.cpuGflops = cpuGflops
        self.memoryCopyGBps = memoryCopyGBps
        self.metalGflops = metalGflops
        self.duration = duration
        self.cancelled = cancelled
    }
}

/// Time-boxed, cancellable benchmark. Total wall time is kept under ~5s:
/// each stage runs for a fixed small number of iterations and the whole run
/// bails out at a hard deadline.
public struct DeviceBenchmark: Sendable {
    /// Hard wall-clock cap for the whole benchmark.
    public var timeBudget: TimeInterval

    public init(timeBudget: TimeInterval = 4.5) {
        self.timeBudget = timeBudget
    }

    public func run() async -> BenchmarkResult {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + .milliseconds(Int(timeBudget * 1000))

        var result = BenchmarkResult()

        if !Task.isCancelled, clock.now < deadline {
            result.cpuGflops = await cpuMatmulGFLOPS(deadline: deadline)
        }
        if !Task.isCancelled, clock.now < deadline {
            result.memoryCopyGBps = memoryCopyThroughputGBps(deadline: deadline)
        }
        if !Task.isCancelled, clock.now < deadline {
            result.metalGflops = metalComputeGFLOPS()
        }

        result.cancelled = Task.isCancelled
        result.duration = clock.now.duration(to: clock.now) == .zero
            ? 0
            : start.duration(to: clock.now).timeInterval
        return result
    }

    // MARK: - CPU matmul

    /// Small Float32 matmul (n=192) repeated until ~1.5s elapsed or deadline.
    /// Reports sustained GFLOPS.
    func cpuMatmulGFLOPS(deadline: ContinuousClock.Instant) async -> Double? {
        let n = 192
        let count = n * n
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        var c = [Float](repeating: 0, count: count)
        for i in 0..<count {
            a[i] = Float((i & 63) + 1) * 0.03125
            b[i] = Float((i & 31) + 1) * 0.0625
        }

        // Warmup
        matmul(a: a, b: b, c: &c, n: n)
        if Task.isCancelled { return nil }

        let clock = ContinuousClock()
        let start = clock.now
        var iterations = 0
        let stageCap = start + .milliseconds(1500)

        while clock.now < stageCap && clock.now < deadline && !Task.isCancelled {
            matmul(a: a, b: b, c: &c, n: n)
            iterations += 1
            if iterations % 8 == 0 { await Task.yield() }
        }
        guard iterations > 0, !Task.isCancelled else { return nil }

        let elapsed = start.duration(to: clock.now).timeInterval
        guard elapsed > 0 else { return nil }
        let flopsPerMatmul = 2.0 * Double(n) * Double(n) * Double(n)
        return flopsPerMatmul * Double(iterations) / elapsed / 1e9
    }

    private func matmul(a: [Float], b: [Float], c: inout [Float], n: Int) {
        // i-k-j loop order for cache-friendly access of b and c rows.
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                c.withUnsafeMutableBufferPointer { pc in
                    for i in 0..<n {
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

    /// memcpy-style throughput over a 64 MB buffer, repeated within the
    /// remaining budget (~1s stage cap).
    func memoryCopyThroughputGBps(deadline: ContinuousClock.Instant) -> Double? {
        let byteCount = 64 * 1024 * 1024
        let src = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 4096)
        let dst = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 4096)
        defer {
            src.deallocate()
            dst.deallocate()
        }
        src.initializeMemory(as: UInt8.self, repeating: 0x5A)
        dst.initializeMemory(as: UInt8.self, repeating: 0)

        let clock = ContinuousClock()
        let start = clock.now
        let stageCap = start + .milliseconds(1000)
        var iterations = 0
        while clock.now < stageCap && clock.now < deadline && !Task.isCancelled {
            dst.copyMemory(from: UnsafeRawBufferPointer(src))
            iterations += 1
        }
        guard iterations > 0, !Task.isCancelled else { return nil }
        let elapsed = start.duration(to: clock.now).timeInterval
        guard elapsed > 0 else { return nil }
        // Count bytes read + written.
        let bytes = Double(byteCount) * 2.0 * Double(iterations)
        return bytes / elapsed / 1e9
    }

    // MARK: - Metal

    func metalComputeGFLOPS() -> Double? {
        #if canImport(Metal)
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
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let kernel = library.makeFunction(name: "bench"),
              let pipeline = try? device.makeComputePipelineState(function: kernel)
        else { return nil }

        let elementCount = 1 << 20 // ~1M threads
        guard let outBuffer = device.makeBuffer(length: elementCount * MemoryLayout<Float>.stride,
                                                options: .storageModeShared)
        else { return nil }
        var scalar: Float = 0.5
        guard let scalarBuffer = device.makeBuffer(bytes: &scalar, length: MemoryLayout<Float>.stride,
                                                   options: .storageModeShared)
        else { return nil }

        // Warmup
        if !encodeRun(queue: queue, pipeline: pipeline, out: outBuffer,
                      scalar: scalarBuffer, count: elementCount) { return nil }

        let clock = ContinuousClock()
        let start = clock.now
        var iterations = 0
        let stageCap = start + .milliseconds(1500)
        while clock.now < stageCap && !Task.isCancelled {
            guard encodeRun(queue: queue, pipeline: pipeline, out: outBuffer,
                            scalar: scalarBuffer, count: elementCount) else { break }
            iterations += 1
        }
        guard iterations > 0, !Task.isCancelled else { return nil }
        let elapsed = start.duration(to: clock.now).timeInterval
        guard elapsed > 0 else { return nil }
        // 2 FLOP per fma iteration * 1024 inner * elementCount threads * iterations
        let flops = 2.0 * 1024.0 * Double(elementCount) * Double(iterations)
        return flops / elapsed / 1e9
        #else
        return nil
        #endif
    }

    #if canImport(Metal)
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
