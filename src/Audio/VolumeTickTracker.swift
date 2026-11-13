import Foundation

struct VolumeTickTracker {
    enum Tick: Equatable {
        case step
        case limit
    }

    let stepCount: Int
    private var lastStep: Int?

    init(stepCount: Int = 50) {
        self.stepCount = stepCount
    }

    mutating func seed(_ volume: Float) {
        lastStep = step(for: volume)
    }

    mutating func tick(for volume: Float) -> Tick? {
        let current = step(for: volume)
        defer { lastStep = current }
        guard let lastStep, lastStep != current else { return nil }
        return current == 0 || current == stepCount ? .limit : .step
    }

    private func step(for volume: Float) -> Int {
        Int((min(max(volume, 0), 1) * Float(stepCount)).rounded())
    }
}
