import KEFKit
import SwiftUI

/// Approved C artwork: pre-rendered official cabinet geometry, dark graphite, no wordmark.
/// Only state transitions animate; there is no 3D renderer, timer or idle animation loop.
struct SpeakerArtwork: View {
    let finish: KEFFinish
    let dimmed: Bool
    let muted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let matched = Self.images[finish.artwork]
        let image = matched ?? Self.images["speakers-graphite-grey"] ?? Image(systemName: "hifispeaker.2")
        ZStack {
            image
                .resizable()
                .scaledToFit()
                // An unknown serial or a finish without artwork must not imply a green pair.
                .saturation(matched == nil ? 0 : (dimmed ? 0.35 : 1))
                .brightness(dimmed ? -0.12 : 0)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 8)
            Image(systemName: "speaker.slash.fill")
                .font(.title3)
                .padding(10)
                .background(.regularMaterial, in: Circle())
                .opacity(muted ? 1 : 0)
        }
        .padding(.vertical, 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: dimmed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: muted)
        .accessibilityHidden(true)
    }

    // Decode the bundled images once, not on every volume or connection update.
    private static let images: [String: Image] = {
        var result: [String: Image] = [:]
        for name in ["speakers-graphite-grey", "speakers-lsxii-green"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                result[name] = Image(nsImage: image)
            }
        }
        return result
    }()
}
