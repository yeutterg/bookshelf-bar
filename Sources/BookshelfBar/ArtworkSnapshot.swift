import AppKit
import KEFKit
import SwiftUI

/// Offline visual check of the production artwork view. Does not start discovery, audio
/// monitoring or speaker control. Usage: BookshelfBar --artwork-snapshot /tmp/artwork.png
@MainActor
func writeArtworkSnapshot(to path: String) throws {
    let graphite = KEFFinish.decode(serial: "LSXLT00000AS29M2GR", modelName: "LSX II LT")
    let content = HStack(spacing: 16) {
        snapshotTile("Playing", finish: graphite, state: .playing)
        snapshotTile("Powering up", finish: graphite, state: .waking)
        snapshotTile("Standby", finish: graphite, state: .standby)
        snapshotTile("Muted", finish: graphite, state: .muted)
        snapshotTile("Unknown finish", finish: .unknown, state: .playing)
    }
    .padding(24)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

@MainActor
private func snapshotTile(_ label: String, finish: KEFFinish, state: SpeakerState) -> some View {
    VStack(spacing: 12) {
        Text(label).font(.headline)
        SpeakerArtwork(finish: finish, state: state)
            .frame(width: 280, height: 140)
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
}
