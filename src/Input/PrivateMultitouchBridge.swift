import Foundation

protocol TrackpadCapturing: AnyObject {
    func start(_ handler: @escaping @Sendable (TrackpadSample) -> Void) throws
    func stop()
    var isRunning: Bool { get }
}

enum TrackpadCaptureError: LocalizedError {
    case unavailable(Int32)

    var errorDescription: String? { "No compatible trackpad device could be started." }
}

private enum CallbackRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (TrackpadSample) -> Void)?

    static func install(_ newHandler: @escaping @Sendable (TrackpadSample) -> Void) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    static func remove() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    static func deliver(contactCount: Int32, contactID: Int32, x: Float, y: Float, deviceID: UInt,
                        filterWallNanoseconds: UInt64, filterCPUNanoseconds: UInt64) {
        let traceID = PipelineLogger.shared.beginTrace()
        let callbackStarted = PipelineLogger.beginMeasurement()
        PipelineLogger.shared.recordDuration(
            traceID: traceID, stage: "trackpad.c-filter",
            wall: filterWallNanoseconds, cpu: filterCPUNanoseconds
        )
        lock.lock()
        let callback = handler
        lock.unlock()
        PipelineLogger.shared.record(traceID: traceID, stage: "bridge.swift-received", at: callbackStarted.wall)
        callback?(TrackpadSample(
            contactCount: Int(contactCount), contactID: Int(contactID), x: x, y: y,
            deviceID: deviceID,
            timestamp: ContinuousClock().now,
            traceID: traceID,
            receivedAtNanoseconds: callbackStarted.wall
        ))
        PipelineLogger.shared.finishMeasurement(callbackStarted, traceID: traceID, stage: "bridge.swift-callback")
    }
}

@_cdecl("glide_trackpad_sample")
private func glide_trackpad_sample(_ count: Int32, _ identifier: Int32, _ x: Float, _ y: Float, _ deviceID: UInt,
                                  _ filterWallNanoseconds: UInt64, _ filterCPUNanoseconds: UInt64) {
    CallbackRegistry.deliver(contactCount: count, contactID: identifier, x: x, y: y, deviceID: deviceID,
                             filterWallNanoseconds: filterWallNanoseconds,
                             filterCPUNanoseconds: filterCPUNanoseconds)
}

final class PrivateMultitouchBridge: TrackpadCapturing {
    var isRunning: Bool { ev_capture_is_running() != 0 }

    func start(_ handler: @escaping @Sendable (TrackpadSample) -> Void) throws {
        CallbackRegistry.install(handler)
        let result = ev_capture_start(glide_trackpad_sample)
        guard result == 0 else {
            CallbackRegistry.remove()
            throw TrackpadCaptureError.unavailable(result)
        }
    }

    func stop() {
        CallbackRegistry.remove()
        ev_capture_stop()
    }
}
