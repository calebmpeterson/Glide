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
    private let minimumWriteInterval: UInt64 = 16_666_667

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
        guard enabled else { return }
        PipelineLogger.shared.record(traceID: sample.traceID, stage: "processor.started")
        guard (0...32).contains(sample.contactCount) else {
            gesture.cancel()
            pendingDelta = 0
            publish(.invalidInput(sample.traceID))
            return
        }

        if sample.contactCount == 0 {
            if let device = gestureDevice { writePendingDelta(for: device, traceID: sample.traceID) }
            _ = gesture.feed(settings: settings, sample: sample, optionIsDown: optionIsDown)
            gestureDevice = nil
            return
        }

        if sample.contactCount != 1 {
            pendingDelta = 0
            _ = gesture.feed(settings: settings, sample: sample, optionIsDown: optionIsDown)
            return
        }

        if gestureDevice == nil {
            gestureDevice = try? audio.currentOutput()
        }
        let delta = gesture.feed(settings: settings, sample: sample, optionIsDown: optionIsDown)
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
            PipelineLogger.shared.record(traceID: traceID, stage: "audio.write-started")
            let volume = try audio.adjust(delta: delta, expectedDevice: device)
            lastAudioWriteAt = DispatchTime.now().uptimeNanoseconds
            PipelineLogger.shared.record(traceID: traceID, stage: "audio.write-finished")
            publish(.volume(volume, traceID))
        } catch {
            gesture.cancel()
            gestureDevice = nil
            pendingDelta = 0
            PipelineLogger.shared.record(traceID: traceID, stage: "audio.write-failed")
            publish(.audioUnavailable(traceID))
        }
    }

    private func publish(_ outcome: Outcome) {
        presentation.submit(outcome)
    }
}

/// Holds only the latest presentation state while the main thread is busy.
/// Audio writes still happen for every gesture frame; this merely prevents the
/// HUD from replaying stale volume values after the finger has moved on.
private final class PresentationDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let receiver: @MainActor @Sendable (GestureProcessor.Outcome) -> Void
    private var latest: GestureProcessor.Outcome?
    private var scheduled = false

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

    private func scheduleDelivery() {
        Task { @MainActor [weak self] in self?.deliverLatest() }
    }

    @MainActor
    private func deliverLatest() {
        lock.lock()
        let outcome = latest
        latest = nil
        lock.unlock()

        if let outcome {
            PipelineLogger.shared.record(traceID: outcome.traceID, stage: "presentation.delivered")
            receiver(outcome)
        }

        lock.lock()
        let needsAnotherDelivery = latest != nil
        if !needsAnotherDelivery { scheduled = false }
        lock.unlock()

        if needsAnotherDelivery { scheduleDelivery() }
    }
}
