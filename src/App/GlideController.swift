import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
final class GlideController: ObservableObject {
    @Published private(set) var settings: Settings
    @Published private(set) var isEnabled = false
    @Published private(set) var volumePercent: Int?
    @Published private(set) var outputIsAdjustable = false
    @Published private(set) var statusMessage = "Paused. Enable Glide to begin observing the trackpad."
    @Published private(set) var lastError: String?

    private let store: SettingsStore
    private let capture: TrackpadCapturing
    private let audio: AudioController
    private let hud = VolumeHUD()
    private lazy var gestureProcessor = GestureProcessor(audio: audio) { [weak self] outcome in
        self?.receive(outcome)
    }
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(
        store: SettingsStore = SettingsStore(),
        capture: TrackpadCapturing = PrivateMultitouchBridge(),
        audio: AudioController = AudioController()
    ) {
        self.store = store
        self.capture = capture
        self.audio = audio
        PipelineLogger.shared.startNewSession()
        settings = store.load()
        configureStatusItem()
        refreshVolume()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshVolume() }
        }
        observeSystemLifecycle()
        if settings.enabled { enable() }
    }

    func updateSettings(_ newSettings: Settings) {
        guard var valid = newSettings.validated() else {
            lastError = "Those settings are not valid."
            return
        }
        valid.enabled = isEnabled
        settings = valid
        store.save(valid)
        if !valid.showsHUD { hud.hide() }
        if isEnabled { gestureProcessor.update(settings: valid) }
    }

    func enable() {
        guard !isEnabled, settings.validated() != nil else { return }
        lastError = nil
        statusMessage = "Starting trackpad observation…"
        do {
            try startCapture()
            isEnabled = true
            settings.enabled = true
            store.save(settings)
            refreshVolume()
            if outputIsAdjustable {
                statusMessage = "Listening for a one-finger edge swipe."
            } else {
                statusMessage = "This output device does not expose an adjustable system volume."
            }
        } catch {
            capture.stop()
            gestureProcessor.pause()
            isEnabled = false
            settings.enabled = false
            statusMessage = "Trackpad unavailable."
            lastError = "A supported built-in trackpad could not be started."
        }
    }

    func disable() {
        guard isEnabled || capture.isRunning else { return }
        capture.stop()
        gestureProcessor.pause()
        isEnabled = false
        settings.enabled = false
        store.save(settings)
        statusMessage = "Paused. No trackpad contact data is being observed."
    }

    func showPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }

    private func startCapture() throws {
        var activeSettings = settings
        activeSettings.enabled = true
        let processor = gestureProcessor
        processor.resume(settings: activeSettings)
        try capture.start { sample in
            processor.submit(sample, optionIsDown: NSEvent.modifierFlags.contains(.option))
        }
    }

    private func receive(_ outcome: GestureProcessor.Outcome) {
        switch outcome {
        case let .volume(updatedVolume, _):
            volumePercent = Int((updatedVolume * 100).rounded())
            updateStatusItem()
            if settings.showsHUD { hud.show(volume: updatedVolume, anchoredTo: statusItem) }
            statusMessage = "Listening for a one-finger edge swipe."
        case .invalidInput:
            statusMessage = "Invalid trackpad input. Lift all fingers and retry."
        case .audioUnavailable:
            statusMessage = "Gesture cancelled. Lift all fingers and retry."
            lastError = "The output device changed or cannot adjust volume."
        }
    }

    private func refreshVolume() {
        do {
            let device = try audio.currentOutput()
            let volume = try audio.readVolume(for: device)
            volumePercent = Int((volume * 100).rounded())
            outputIsAdjustable = audio.isVolumeSettable(for: device)
            if !isEnabled { statusMessage = "Paused. Enable Glide to begin observing the trackpad." }
        } catch {
            volumePercent = nil
            outputIsAdjustable = false
            if !isEnabled { statusMessage = "Current output volume is unavailable." }
        }
        updateStatusItem()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeft
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.font = .menuBarFont(ofSize: 0)
        let menu = NSMenu()
        let preferences = NSMenuItem(title: "Show Glide", action: #selector(openPreferences), keyEquivalent: "")
        preferences.target = self
        menu.addItem(preferences)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Glide", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        let percentage = volumePercent.map { "\($0)%" } ?? "--%"
        let symbol = GlideVolumeSymbol.name(for: volumePercent)
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "System volume")
        statusItem?.button?.title = percentage
        statusItem?.button?.toolTip = "System volume: \(percentage)"
        statusItem?.button?.setAccessibilityLabel("System volume: \(percentage)")
    }

    private func observeSystemLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.suspendForSystemChange() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.suspendForSystemChange() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartAfterSystemChange() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartAfterSystemChange() }
        })
    }

    private func suspendForSystemChange() {
        guard isEnabled else { return }
        capture.stop()
        gestureProcessor.pause()
        statusMessage = "Paused while the Mac is unavailable."
    }

    private func restartAfterSystemChange() {
        guard isEnabled else { return }
        capture.stop()
        gestureProcessor.pause()
        do {
            try startCapture()
            statusMessage = "Listening for a one-finger edge swipe."
        } catch {
            isEnabled = false
            settings.enabled = false
            statusMessage = "Trackpad unavailable."
            lastError = "A supported built-in trackpad could not be restarted."
        }
    }

    @objc private func openPreferences() { showPreferences() }
    @objc private func quit() { NSApp.terminate(nil) }
}
