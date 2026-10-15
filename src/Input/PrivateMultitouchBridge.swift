import Foundation

protocol TrackpadCapturing: AnyObject {
    func start(_ handler: @escaping @Sendable (TrackpadSample) -> Void) throws
    func stop()
    var isRunning: Bool { get }
}

enum TrackpadCaptureError: LocalizedError {
    case unavailable(Int32)

    var errorDescription: String? { "A supported built-in trackpad could not be started." }
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

    static func deliver(contactCount: Int32, contactID: Int32, x: Float, y: Float) {
        lock.lock()
        let callback = handler
        lock.unlock()
        let traceID = PipelineLogger.shared.beginTrace()
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        PipelineLogger.shared.record(traceID: traceID, stage: "bridge.swift-received", at: receivedAt)
        callback?(TrackpadSample(
            contactCount: Int(contactCount), contactID: Int(contactID), x: x, y: y,
            timestamp: ContinuousClock().now,
            traceID: traceID,
            receivedAtNanoseconds: receivedAt
        ))
    }
}

@_cdecl("glide_trackpad_sample")
private func glide_trackpad_sample(_ count: Int32, _ identifier: Int32, _ x: Float, _ y: Float) {
    CallbackRegistry.deliver(contactCount: count, contactID: identifier, x: x, y: y)
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
