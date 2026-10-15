import AppKit

enum GlideVolumeSymbol {
    static func name(for percent: Int?) -> String {
        switch percent ?? 0 {
        case ...0: "speaker.slash.fill"
        case 1...33: "speaker.fill"
        case 34...66: "speaker.wave.1.fill"
        default: "speaker.wave.2.fill"
        }
    }
}

@MainActor
final class VolumeHUD {
    private let panel: NSPanel
    private let content: VolumeHUDView
    private var dismissWorkItem: DispatchWorkItem?

    init() {
        content = VolumeHUDView(frame: NSRect(x: 0, y: 0, width: 248, height: 52))
        panel = NSPanel(
            contentRect: content.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.title = "Glide volume indicator"
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.063, green: 0.09, blue: 0.078, alpha: 1).cgColor
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.setAccessibilityRole(.group)
    }

    func show(volume: Float) {
        let boundedVolume = min(max(volume, 0), 1)
        content.volume = boundedVolume
        let percent = Int((boundedVolume * 100).rounded())
        content.symbolName = GlideVolumeSymbol.name(for: percent)
        content.setAccessibilityLabel("System volume \(percent) percent")
        content.needsDisplay = true

        if !panel.isVisible {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 278, y: frame.minY + 30))
            }
            panel.orderFrontRegardless()
        }

        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: workItem)
    }
}

private final class VolumeHUDView: NSView {
    var volume: Float = 0
    var symbolName = "speaker.wave.2.fill"

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.063, green: 0.09, blue: 0.078, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).fill()
        let mint = NSColor(calibratedRed: 0.55, green: 0.87, blue: 0.67, alpha: 1)
        let percentage = "\(Int((volume * 100).rounded()))%"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white
        ]
        let size = percentage.size(withAttributes: attributes)
        percentage.draw(at: NSPoint(x: 230 - size.width, y: 16), withAttributes: attributes)
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Volume level")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) {
            symbol.draw(in: NSRect(x: 18, y: 18, width: 16, height: 16))
        }
        let track = NSRect(x: 43, y: 23, width: 137, height: 6)
        NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        mint.setFill()
        let progress = NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(volume), height: track.height)
        if progress.width > 0 {
            NSBezierPath(roundedRect: progress, xRadius: 3, yRadius: 3).fill()
        }
    }
}
