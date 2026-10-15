import Darwin
import Foundation

/// Temporary, bounded latency instrumentation. Entries contain generated trace
/// IDs, monotonic timestamps, and stage names only; no touch or audio values.
final class PipelineLogger: @unchecked Sendable {
    static let shared = PipelineLogger()
    static let logURL = URL(fileURLWithPath: "/tmp/Glide-pipeline.log")
    // Set to true temporarily when collecting a diagnostic trace.
    private let isEnabled = false

    private let writeQueue = DispatchQueue(label: "com.glide.pipeline-log", qos: .utility)
    private let sequenceLock = NSLock()
    private var nextSequence = UInt64.zero
    private var handle: FileHandle?
    private var bytesWritten = 0
    private let maximumBytes = 1_000_000

    private init() {}

    func startNewSession() {
        guard isEnabled else { return }
        writeQueue.sync {
            try? handle?.close()
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: Self.logURL)
            bytesWritten = 0
            append("# Glide pipeline trace — monotonic nanoseconds only\n")
        }
    }

    func beginTrace() -> UInt64 {
        guard isEnabled else { return 0 }
        sequenceLock.lock()
        nextSequence &+= 1
        let traceID = nextSequence
        sequenceLock.unlock()
        return traceID
    }

    struct Measurement {
        let wall: UInt64
        let cpu: UInt64
    }

    static func beginMeasurement() -> Measurement {
        guard shared.isEnabled else { return Measurement(wall: 0, cpu: 0) }
        return Measurement(wall: DispatchTime.now().uptimeNanoseconds, cpu: threadCPUTime())
    }

    func finishMeasurement(_ measurement: Measurement, traceID: UInt64, stage: String) {
        guard isEnabled else { return }
        let wall = DispatchTime.now().uptimeNanoseconds &- measurement.wall
        let cpu = Self.threadCPUTime() &- measurement.cpu
        recordDuration(traceID: traceID, stage: stage, wall: wall, cpu: cpu)
    }

    func recordDuration(traceID: UInt64, stage: String, wall: UInt64, cpu: UInt64? = nil) {
        guard isEnabled else { return }
        writeQueue.async { [weak self] in
            let cpuField = cpu.map { " cpu_ns=\($0)" } ?? ""
            self?.append("\(DispatchTime.now().uptimeNanoseconds) trace=\(traceID) stage=\(stage) wall_ns=\(wall)\(cpuField)\n")
        }
    }

    private static func threadCPUTime() -> UInt64 {
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { return 0 }
        return UInt64(time.tv_sec) &* 1_000_000_000 &+ UInt64(time.tv_nsec)
    }

    func record(traceID: UInt64, stage: String, at timestamp: UInt64? = nil) {
        guard isEnabled else { return }
        let timestamp = timestamp ?? DispatchTime.now().uptimeNanoseconds
        writeQueue.async { [weak self] in
            self?.append("\(timestamp) trace=\(traceID) stage=\(stage)\n")
        }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8), let handle else { return }
        if bytesWritten + data.count > maximumBytes {
            try? handle.truncate(atOffset: 0)
            try? handle.seek(toOffset: 0)
            bytesWritten = 0
        }
        try? handle.write(contentsOf: data)
        bytesWritten += data.count
    }
}
