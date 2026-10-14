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

/// Two high-contrast speaker cabinets: outlined while inactive, filled while active.
struct MenuBarGlyph: View {
    let state: SpeakerState

    var body: some View {
        ZStack {
            HStack(spacing: 3.2) {
                MenuBarCabinet(filled: filled)
                MenuBarCabinet(filled: filled)
            }

            if state == .muted {
                Capsule()
                    .fill(.primary)
                    .frame(width: 1.35, height: 17)
                    .rotationEffect(.degrees(45))
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .frame(width: 22, height: 14)
        .environment(\.colorScheme, .light)   // .primary = black, as a template image expects
    }

    private var filled: Bool {
        switch state {
        case .on, .playing, .muted: true
        case .offline, .reconnecting, .standby, .waking: false
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
    let filled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(filled ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .stroke(.primary, lineWidth: 1.05)
            if filled {
                Circle()
                    .fill(.primary)
                    .frame(width: 4.4, height: 4.4)
                    .blendMode(.destinationOut)
            } else {
                Circle()
                    .stroke(.primary, lineWidth: 0.9)
                    .frame(width: 4.4, height: 4.4)
            }
            Circle()
                .fill(.primary)
                .frame(width: 1.2, height: 1.2)
        }
        .compositingGroup()
        .frame(width: 6, height: 11)
    }
}
