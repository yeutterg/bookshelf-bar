import AppKit
import BookshelfBarCore
import SwiftUI

/// Menu bar label. `MenuBarExtra` labels only render `Image` and `Text` (arbitrary shapes come
/// out empty and the status item disappears), so the drawn glyph is rendered to a template
/// image per state and cached. Template images follow the menu bar's light/dark appearance.
struct MenuBarIcon: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart

    var body: some View {
        let state = speaker.visualState(smoothStart)
        Image(nsImage: MenuBarGlyph.image(for: state))
            .accessibilityLabel(MenuBarGlyph.label(state))
    }
}

/// The compact two-cabinet glyph from the Paper prototype, drawn for one state.
struct MenuBarGlyph: View {
    let state: SpeakerState

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                MenuBarCabinet(leansLeft: false, emphasized: emphasized)
                MenuBarCabinet(leansLeft: true, emphasized: emphasized)
            }
            if state == .playing || state == .waking || state == .reconnecting {
                MenuBarActivity()
            }
            if state == .muted {
                Capsule()
                    .fill(.primary)
                    .frame(width: 1.5, height: 21)
                    .rotationEffect(.degrees(45))
            }
        }
        .frame(width: 21, height: 16)
        .opacity(opacity)
        .environment(\.colorScheme, .light)   // .primary = black, as a template image expects
    }

    private var emphasized: Bool {
        switch state {
        case .on, .playing, .waking: true
        case .offline, .reconnecting, .standby, .muted: false
        }
    }

    private var opacity: Double {
        switch state {
        case .offline: 0.38
        case .standby: 0.58
        case .reconnecting: 0.7
        case .waking, .on, .playing, .muted: 1
        }
    }

    static func label(_ state: SpeakerState) -> String {
        switch state {
        case .offline: "Speakers offline"
        case .reconnecting: "Speakers reconnecting"
        case .standby: "Speakers in standby"
        case .waking: "Speakers powering up"
        case .on: "Speakers on"
        case .playing: "Speakers playing"
        case .muted: "Speakers muted"
        }
    }

    @MainActor private static var cache: [SpeakerState: NSImage] = [:]

    @MainActor static func image(for state: SpeakerState) -> NSImage {
        if let cached = cache[state] { return cached }
        let renderer = ImageRenderer(content: MenuBarGlyph(state: state))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: nil)!
        image.isTemplate = true
        cache[state] = image
        return image
    }
}

private struct MenuBarCabinet: View {
    let leansLeft: Bool
    let emphasized: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.25, style: .continuous)
                .fill(.primary.opacity(emphasized ? 0.16 : 0.04))
            RoundedRectangle(cornerRadius: 2.25, style: .continuous)
                .stroke(.primary, lineWidth: emphasized ? 1.15 : 0.95)
            Circle()
                .stroke(.primary, lineWidth: 0.9)
                .frame(width: 4.7, height: 4.7)
                .offset(y: -1.2)
            Circle()
                .fill(.primary)
                .frame(width: emphasized ? 1.8 : 1.35, height: emphasized ? 1.8 : 1.35)
                .offset(y: -1.2)
            Circle()
                .fill(.primary.opacity(0.8))
                .frame(width: 0.9, height: 0.9)
                .offset(y: 4.6)
        }
        .frame(width: 7.5, height: 14)
        .rotationEffect(.degrees(leansLeft ? -2.5 : 2.5), anchor: .bottom)
    }
}

/// Two soft rings next to the drivers for playing / waking. Static: it's rendered into the
/// menu bar image.
private struct MenuBarActivity: View {
    var body: some View {
        ZStack {
            ring(x: -4.75)
            ring(x: 4.75)
        }
    }

    private func ring(x: CGFloat) -> some View {
        Circle()
            .stroke(.primary.opacity(0.45), lineWidth: 0.85)
            .frame(width: 5.2, height: 5.2)
            .scaleEffect(1.5)
            .offset(x: x, y: -1.2)
    }
}
