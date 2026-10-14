import AppKit
import KEFBarCore
import SwiftUI

/// Speaker-pair glyph for the menu bar: dimmed in standby, filled drivers when on, a slash when
/// muted, and amber while Smooth Start is waking the speakers.
struct MenuBarIcon: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart

    var body: some View {
        Image(nsImage: Self.image(for: speaker.visualState(smoothStart)))
    }

    static func image(for state: SpeakerState) -> NSImage {
        let size = NSSize(width: 20, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            let ink: NSColor = state == .waking ? .systemOrange : .black
            let alpha: CGFloat = state == .standby || state == .offline ? 0.5 : 1
            ink.withAlphaComponent(alpha).set()
            for x in [1.5, 11.5] {
                let cabinet = NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: 7, height: 12), xRadius: 2, yRadius: 2)
                cabinet.lineWidth = 1.3
                cabinet.stroke()
                let driver = NSBezierPath(ovalIn: NSRect(x: x + 1.3, y: 4.3, width: 4.4, height: 4.4))
                if state == .playing || state == .waking { driver.fill() } else { driver.lineWidth = 1.1; driver.stroke() }
            }
            if state == .muted {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 1, y: 0.5))
                slash.line(to: NSPoint(x: 19, y: 13.5))
                slash.lineWidth = 1.4
                slash.lineCapStyle = .round
                slash.stroke()
            }
            return true
        }
        // Template images follow the menu bar's light/dark appearance; the amber one keeps its color.
        image.isTemplate = state != .waking
        return image
    }
}
