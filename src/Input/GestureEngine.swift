import Foundation

struct TrackpadSample: Sendable {
    let contactCount: Int
    let contactID: Int
    let x: Float
    let y: Float
    let timestamp: ContinuousClock.Instant
    let traceID: UInt64
    let receivedAtNanoseconds: UInt64
}

struct GestureEngine: Sendable {
    private var contactID: Int?
    private var startedOnLeft = false
    private var originX: Float = 0
    private var originY: Float = 0
    private var previousY: Float = 0
    private var lastTimestamp: ContinuousClock.Instant?
    private var active = false
    private var rejected = false

    mutating func feed(settings: Settings, sample: TrackpadSample, optionIsDown: Bool) -> Float? {
        if sample.contactCount == 0 {
            reset()
            return nil
        }

        let elapsed = lastTimestamp.map { $0.duration(to: sample.timestamp) }
        lastTimestamp = sample.timestamp
        if let elapsed, elapsed <= .zero || elapsed > .milliseconds(250) {
            cancel()
            return nil
        }

        guard settings.enabled,
              sample.contactCount == 1,
              (!settings.requireOption || optionIsDown),
              (0...1).contains(sample.x),
              (0...1).contains(sample.y)
        else {
            cancel()
            return nil
        }

        guard !rejected else { return nil }

        guard let latchedID = contactID else {
            let onLeft = settings.edge != .right && sample.x <= settings.edgeWidth
            let onRight = settings.edge != .left && sample.x >= 1 - settings.edgeWidth
            guard onLeft || onRight else {
                cancel()
                return nil
            }
            contactID = sample.contactID
            startedOnLeft = onLeft
            originX = sample.x
            originY = sample.y
            previousY = sample.y
            return nil
        }

        let remainsOnEdge = startedOnLeft ? sample.x <= settings.edgeWidth : sample.x >= 1 - settings.edgeWidth
        let horizontalDistance = sample.x - originX
        let verticalDistance = sample.y - originY
        let stepY = sample.y - previousY
        guard latchedID == sample.contactID,
              remainsOnEdge,
              abs(horizontalDistance) <= 0.06,
              abs(stepY) <= 0.15
        else {
            cancel()
            return nil
        }
        previousY = sample.y

        if !active {
            guard abs(verticalDistance) >= 0.03 else { return nil }
            guard abs(horizontalDistance) <= abs(verticalDistance) * 0.6 else {
                cancel()
                return nil
            }
            active = true
        }

        let maximumStep = 0.6 * min(seconds(in: elapsed ?? .zero), 0.1)
        let limitedStep = min(max(stepY * settings.sensitivity, -maximumStep), maximumStep)
        return limitedStep * (settings.inverted ? -1 : 1)
    }

    mutating func cancel() {
        rejected = true
        active = false
    }

    mutating func reset() {
        self = Self()
    }

    private func seconds(in duration: Duration) -> Float {
        let components = duration.components
        return Float(Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
