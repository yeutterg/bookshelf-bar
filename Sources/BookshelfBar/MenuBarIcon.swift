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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(filled ? 0.3 : 0.035))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.primary.opacity(outlineOpacity), lineWidth: 0.85)

            HStack(spacing: 2) {
                MenuBarCabinet()
                MenuBarCabinet()
            }
            .opacity(glyphOpacity)
            .blendMode(filled ? .destinationOut : .normal)

            if state == .muted {
                Capsule()
                    .fill(.primary)
                    .frame(width: 1.25, height: 15)
                    .rotationEffect(.degrees(45))
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .frame(width: 22, height: 14)
        .opacity(state == .offline ? 0.55 : 1)
        .environment(\.colorScheme, .light)   // .primary = black, as a template image expects
    }

    /// Paper frame 06 has four treatments. Extra runtime states intentionally fold into the
    /// closest one so the status item keeps the same visual language.
    private var filled: Bool {
        switch state {
        case .on, .playing, .muted: true
        case .offline, .reconnecting, .standby, .waking: false
        }
    }

    private var outlineOpacity: Double {
        switch state {
        case .waking, .reconnecting: 0.55
        case .standby, .offline: 0.13
        case .on, .playing, .muted: 0
        }
    }

    private var glyphOpacity: Double {
        switch state {
        case .waking, .reconnecting: 0.58
        case .standby, .offline: 0.2
        case .on, .playing, .muted: 0.72
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
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .stroke(.primary, lineWidth: 0.9)
            Circle()
                .stroke(.primary, lineWidth: 0.75)
                .frame(width: 3.1, height: 3.1)
                .offset(y: -0.7)
            Circle()
                .fill(.primary)
                .frame(width: 0.9, height: 0.9)
                .offset(y: -0.7)
        }
        .frame(width: 5, height: 9)
    }
}
