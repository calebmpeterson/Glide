import AppKit
import CoreAudio
import Foundation

/// Owns the serial, non-UI path from a contact frame to one CoreAudio write.
/// It has no buffer: each callback is processed in arrival order on this queue.
final class GestureProcessor: @unchecked Sendable {
    enum Outcome: Sendable {
        case volume(Float, UInt64)
        case invalidInput(UInt64)
        case audioUnavailable(UInt64)

        var traceID: UInt64 {
            switch self {
            case let .volume(_, traceID), let .invalidInput(traceID), let .audioUnavailable(traceID): traceID
            }
        }
    }

    private let queue = DispatchQueue(label: "com.glide.input", qos: .userInteractive)
    private let audio: AudioController
    private let presentation: PresentationDelivery
    private var settings = Settings.default
    private var gesture = GestureEngine()
    private var gestureDevice: AudioDeviceID?
    private var enabled = false
    private var pendingDelta: Float = 0
    private var lastAudioWriteAt: UInt64?
    // Allow audio writes at up to 120 Hz so gesture deltas are accumulated for
    // less time before reaching CoreAudio.
    private let minimumWriteInterval: UInt64 = 8_333_333

    init(audio: AudioController, receiver: @escaping @MainActor @Sendable (Outcome) -> Void) {
        self.audio = audio
        presentation = PresentationDelivery(receiver: receiver)
    }

    func resume(settings: Settings) {
        queue.sync {
            self.settings = settings
            enabled = true
            gesture.reset()
            gestureDevice = nil
            pendingDelta = 0
            lastAudioWriteAt = nil
        }
    }

    func update(settings: Settings) {
        queue.async { [weak self] in self?.settings = settings }
    }

    func pause() {
        queue.sync {
            enabled = false
            gesture.cancel()
            gestureDevice = nil
            pendingDelta = 0
            lastAudioWriteAt = nil
        }
    }

    func submit(_ sample: TrackpadSample, optionIsDown: Bool) {
        PipelineLogger.shared.record(traceID: sample.traceID, stage: "processor.enqueued")
        queue.async { [weak self] in self?.process(sample, optionIsDown: optionIsDown) }
    }

    private func process(_ sample: TrackpadSample, optionIsDown: Bool) {
        let frameStarted = PipelineLogger.beginMeasurement()
        defer { PipelineLogger.shared.finishMeasurement(frameStarted, traceID: sample.traceID, stage: "processor.frame") }
        PipelineLogger.shared.record(traceID: sample.traceID, stage: "processor.started")
        PipelineLogger.shared.recordDuration(
            traceID: sample.traceID,
            stage: "processor.queue-wait",
            wall: frameStarted.wall &- sample.receivedAtNanoseconds
        )
        guard enabled else { return }
        guard (0...32).contains(sample.contactCount) else {
            gesture.cancel()
            pendingDelta = 0
            publish(.invalidInput(sample.traceID))
            return
        }

        if sample.contactCount == 0 {
            if let device = gestureDevice { writePendingDelta(for: device, traceID: sample.traceID) }
            _ = feedGesture(sample, optionIsDown: optionIsDown)
            gestureDevice = nil
            return
        }

        if sample.contactCount != 1 {
            pendingDelta = 0
            _ = feedGesture(sample, optionIsDown: optionIsDown)
            return
        }

        if gestureDevice == nil {
            let measurement = PipelineLogger.beginMeasurement()
            gestureDevice = try? audio.currentOutput()
            PipelineLogger.shared.finishMeasurement(measurement, traceID: sample.traceID, stage: "audio.current-output")
        }
        let delta = feedGesture(sample, optionIsDown: optionIsDown)
        guard let device = gestureDevice else { return }
        if delta == nil, pendingDelta != 0 {
            // A previously active gesture was rejected; do not flush its last step.
            pendingDelta = 0
            return
        }
        if let delta { pendingDelta += delta }

        let now = DispatchTime.now().uptimeNanoseconds
        guard pendingDelta != 0,
              lastAudioWriteAt.map({ now - $0 >= minimumWriteInterval }) ?? true
        else { return }
        writePendingDelta(for: device, traceID: sample.traceID)
    }

    private func writePendingDelta(for device: AudioDeviceID, traceID: UInt64) {
        guard pendingDelta != 0 else { return }
        let delta = pendingDelta
        pendingDelta = 0

        do {
            PipelineLogger.shared.record(traceID: traceID, stage: "audio.adjust-started")
            let measurement = PipelineLogger.beginMeasurement()
            let volume = try audio.adjust(delta: delta, expectedDevice: device, traceID: traceID)
            PipelineLogger.shared.finishMeasurement(measurement, traceID: traceID, stage: "audio.adjust-total")
            PipelineLogger.shared.record(traceID: traceID, stage: "audio.adjust-finished")
            lastAudioWriteAt = DispatchTime.now().uptimeNanoseconds
            publish(.volume(volume, traceID))
        } catch {
            PipelineLogger.shared.record(traceID: traceID, stage: "audio.adjust-failed")
            gesture.cancel()
            gestureDevice = nil
            pendingDelta = 0
            publish(.audioUnavailable(traceID))
        }
    }

    private func feedGesture(_ sample: TrackpadSample, optionIsDown: Bool) -> Float? {
        let measurement = PipelineLogger.beginMeasurement()
        let delta = gesture.feed(settings: settings, sample: sample, optionIsDown: optionIsDown)
        PipelineLogger.shared.finishMeasurement(measurement, traceID: sample.traceID, stage: "gesture.feed")
        return delta
    }

    private func publish(_ outcome: Outcome) {
        presentation.submit(outcome)
    }
}

/// Holds only the latest presentation state while the main thread is busy.
/// Audio writes still happen for every gesture frame; this merely prevents the
/// HUD from replaying stale volume values after the finger has moved on.
private final class PresentationDelivery: @unchecked Sendable {
    private let minimumDeliveryInterval: UInt64 = 16_666_667
    private let lock = NSLock()
    private let receiver: @MainActor @Sendable (GestureProcessor.Outcome) -> Void
    private var latest: GestureProcessor.Outcome?
    private var scheduled = false
    private var lastDeliveryAt: UInt64?

    init(receiver: @escaping @MainActor @Sendable (GestureProcessor.Outcome) -> Void) {
        self.receiver = receiver
    }

    func submit(_ outcome: GestureProcessor.Outcome) {
        PipelineLogger.shared.record(traceID: outcome.traceID, stage: "presentation.queued")
        lock.lock()
        latest = outcome
        guard !scheduled else {
            lock.unlock()
            return
        }
        scheduled = true
        lock.unlock()
        scheduleDelivery()
    }

    private func scheduleDelivery(after delay: UInt64 = 0) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            self?.deliverLatest()
        }
    }

    @MainActor
    private func deliverLatest() {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        if let lastDeliveryAt, now - lastDeliveryAt < minimumDeliveryInterval {
            let delay = minimumDeliveryInterval - (now - lastDeliveryAt)
            lock.unlock()
            scheduleDelivery(after: delay)
            return
        }
        let outcome = latest
        latest = nil
        if outcome != nil { lastDeliveryAt = now }
        lock.unlock()

        if let outcome {
            let measurement = PipelineLogger.beginMeasurement()
            receiver(outcome)
            PipelineLogger.shared.finishMeasurement(measurement, traceID: outcome.traceID, stage: "presentation.receiver")
        }

        lock.lock()
        let needsAnotherDelivery = latest != nil
        if !needsAnotherDelivery { scheduled = false }
        lock.unlock()

        if needsAnotherDelivery { scheduleDelivery() }
    }
}
