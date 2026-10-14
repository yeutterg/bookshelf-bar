import AppKit
import SwiftUI

/// Icons drawn in the Paper design, shipped as SVG and rendered as template images so they
/// take the surrounding foreground style like SF Symbols do.
struct PaperIcon: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        if let image = Self.load(name) {
            Image(nsImage: image).renderingMode(.template)
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func load(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
