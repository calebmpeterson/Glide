import Foundation

/// Temporary, bounded latency instrumentation. Entries contain generated trace
/// IDs, monotonic timestamps, and stage names only; no touch or audio values.
final class PipelineLogger: @unchecked Sendable {
    static let shared = PipelineLogger()
    static let logURL = URL(fileURLWithPath: "/tmp/Glide-pipeline.log")

    private let writeQueue = DispatchQueue(label: "com.glide.pipeline-log", qos: .utility)
    private let sequenceLock = NSLock()
    private var nextSequence = UInt64.zero
    private var handle: FileHandle?
    private var bytesWritten = 0
    private let maximumBytes = 1_000_000

    private init() {}

    func startNewSession() {
        writeQueue.sync {
            try? handle?.close()
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: Self.logURL)
            bytesWritten = 0
            append("# Glide pipeline trace — monotonic nanoseconds only\n")
        }
    }

    func beginTrace() -> UInt64 {
        sequenceLock.lock()
        nextSequence &+= 1
        let traceID = nextSequence
        sequenceLock.unlock()
        return traceID
    }

    func record(traceID: UInt64, stage: String, at timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds) {
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
