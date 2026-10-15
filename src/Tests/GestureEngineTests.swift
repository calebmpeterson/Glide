import Foundation

@main
struct GestureEngineTests {
    static func main() {
        testDisabledNeverAdjusts()
        testIntentionalVerticalGestureIsRateLimited()
        testDirectionCanReverseWithinOneGesture()
        testMultitouchRejectsUntilLifted()
        testOptionAndInversion()
        testBothEdgesAndMalformedSamples()
        testSettingsValidation()
        print("GestureEngineTests passed")
    }

    private static func testDisabledNeverAdjusts() {
        var gesture = GestureEngine()
        let clock = ContinuousClock()
        let base = clock.now
        expect(gesture.feed(settings: .default, sample: sample(1, 1, 0.98, 0.3, base), optionIsDown: false) == nil)
    }

    private static func testIntentionalVerticalGestureIsRateLimited() {
        var settings = Settings.default
        settings.enabled = true
        var gesture = GestureEngine()
        let clock = ContinuousClock()
        let base = clock.now
        expect(gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.30, base), optionIsDown: false) == nil)
        expect(gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.34, base.advanced(by: .milliseconds(16))), optionIsDown: false) != nil)
        let capped = gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.48, base.advanced(by: .milliseconds(32))), optionIsDown: false)
        expect(capped != nil && capped! <= 0.0097, "volume change must be capped by elapsed time")
    }

    private static func testMultitouchRejectsUntilLifted() {
        var settings = Settings.default
        settings.enabled = true
        var gesture = GestureEngine()
        let clock = ContinuousClock()
        let base = clock.now
        _ = gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.30, base), optionIsDown: false)
        expect(gesture.feed(settings: settings, sample: sample(2, 1, 0.98, 0.34, base.advanced(by: .milliseconds(16))), optionIsDown: false) == nil)
        expect(gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.40, base.advanced(by: .milliseconds(32))), optionIsDown: false) == nil)
        _ = gesture.feed(settings: settings, sample: sample(0, 0, 0, 0, base.advanced(by: .milliseconds(48))), optionIsDown: false)
        expect(gesture.feed(settings: settings, sample: sample(1, 2, 0.98, 0.30, base.advanced(by: .milliseconds(64))), optionIsDown: false) == nil)
    }

    private static func testDirectionCanReverseWithinOneGesture() {
        var settings = Settings.default
        settings.enabled = true
        var gesture = GestureEngine()
        let clock = ContinuousClock()
        let base = clock.now
        _ = gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.30, base), optionIsDown: false)
        let upward = gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.34, base.advanced(by: .milliseconds(16))), optionIsDown: false)
        let downward = gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.30, base.advanced(by: .milliseconds(32))), optionIsDown: false)
        expect(upward != nil && upward! > 0, "upward movement should raise volume")
        expect(downward != nil && downward! < 0, "a reversal must lower volume without lifting")
    }

    private static func testOptionAndInversion() {
        var settings = Settings.default
        settings.enabled = true
        settings.requireOption = true
        settings.inverted = true
        var gesture = GestureEngine()
        let clock = ContinuousClock()
        let base = clock.now
        expect(gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.30, base), optionIsDown: false) == nil)
        _ = gesture.feed(settings: settings, sample: sample(0, 0, 0, 0, base.advanced(by: .milliseconds(16))), optionIsDown: false)
        expect(gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.30, base.advanced(by: .milliseconds(32))), optionIsDown: true) == nil)
        let result = gesture.feed(settings: settings, sample: sample(1, 1, 0.98, 0.34, base.advanced(by: .milliseconds(48))), optionIsDown: true)
        expect(result != nil && result! < 0, "inversion should reverse a rising swipe")
    }

    private static func testBothEdgesAndMalformedSamples() {
        var settings = Settings.default
        settings.enabled = true
        settings.edge = .both
        var gesture = GestureEngine()
        let clock = ContinuousClock()
        let base = clock.now
        expect(gesture.feed(settings: settings, sample: sample(1, 1, 0.02, 0.30, base), optionIsDown: false) == nil)
        expect(gesture.feed(settings: settings, sample: sample(1, 1, 0.02, 0.34, base.advanced(by: .milliseconds(16))), optionIsDown: false) != nil)
        _ = gesture.feed(settings: settings, sample: sample(0, 0, 0, 0, base.advanced(by: .milliseconds(32))), optionIsDown: false)
        expect(gesture.feed(settings: settings, sample: sample(1, 2, 1.2, 0.30, base.advanced(by: .milliseconds(48))), optionIsDown: false) == nil)
    }

    private static func testSettingsValidation() {
        var settings = Settings.default
        settings.edgeWidth = 0.02
        expect(settings.validated() == nil)
        settings = .default
        settings.excludedBundleIDs = Array(repeating: "com.example.App", count: 33)
        expect(settings.validated() == nil)
    }

    private static func sample(_ count: Int, _ id: Int, _ x: Float, _ y: Float, _ timestamp: ContinuousClock.Instant) -> TrackpadSample {
        TrackpadSample(
            contactCount: count, contactID: id, x: x, y: y, timestamp: timestamp,
            traceID: 0, receivedAtNanoseconds: 0
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String = "expectation failed") {
        if !condition() { fatalError(message) }
    }
}
