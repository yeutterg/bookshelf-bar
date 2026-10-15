import KEFKit
import SwiftUI

/// Approved C artwork: pre-rendered official cabinet geometry, dark graphite, no wordmark.
/// Only state transitions animate; there is no 3D renderer, timer or idle animation loop.
struct SpeakerArtwork: View {
    let finish: KEFFinish
    let state: SpeakerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // SwiftUI drives repeating animations from the CPU every frame, and the menu bar panel can
    // stay alive while hidden. Only pulse while it's on screen. (Not `appearsActive`: a menu
    // bar-only app's panel never counts as active, so that kept the pulse from ever running.)
    @State private var onScreen = true

    var body: some View {
        let matched = Self.images[finish.artwork]
        let image = matched ?? Self.images["speakers-graphite-grey"] ?? Image(systemName: "hifispeaker.2")
        GeometryReader { proxy in
            let artworkAspect: CGFloat = 870 / 528
            let width = min(proxy.size.width, proxy.size.height * artworkAspect)
            let height = width / artworkAspect
            ZStack {
                image
                    .resizable()
                    .scaledToFit()
                    // An unknown serial or missing asset must not imply a specific finish.
                    .saturation(matched == nil ? 0 : (dimmed ? 0.35 : 1))
                    .brightness(dimmed ? -0.12 : 0)
                    .shadow(color: .black.opacity(0.24), radius: 8, y: 7)

                if state == .playing || state == .waking {
                    // `id` restarts the pulse cleanly when motion is switched back on.
                    SpeakerPulse(state: state, reduceMotion: still)
                        .position(x: width * 0.257, y: height * 0.515)
                        .id(still)
                    SpeakerPulse(state: state, reduceMotion: still)
                        .position(x: width * 0.743, y: height * 0.515)
                        .id(still)
                }

                ZStack {
                    Circle().fill(.black.opacity(0.68))
                    Circle().stroke(.white.opacity(0.18), lineWidth: 1)
                    Image(systemName: "speaker.slash.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                    .frame(width: 38, height: 38)
                    .opacity(state == .muted ? 1 : 0)
            }
            .frame(width: width, height: height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(WindowVisibility(visible: $onScreen))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: dimmed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state)
        .accessibilityHidden(true)
    }

    private var still: Bool { reduceMotion || !onScreen }

    private var dimmed: Bool { state == .offline || state == .reconnecting || state == .standby }

    // Decode the bundled images once, not on every volume or connection update.
    private static let images: [String: Image] = {
        var result: [String: Image] = [:]
        for name in [
            "speakers-graphite-grey", "speakers-stone-white", "speakers-sage-green",
            "speakers-carbon-black", "speakers-mineral-white", "speakers-cobalt-blue",
            "speakers-lava-red", "speakers-lsxii-green", "speakers-soundwave",
            "speakers-cotton-white", "speakers-amber-haze",
        ] {
            if let url = Bundle.module.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                result[name] = Image(nsImage: image)
            }
        }
        return result
    }()
}

/// Two Core Animation-backed vector rings per driver. They run only while playing or waking;
/// there is no display link, timer, 3D scene or work at rest.
private struct SpeakerPulse: View {
    let state: SpeakerState
    let reduceMotion: Bool
    @State private var expanded = false

    var body: some View {
        ZStack {
            // A very small driver "breath" keeps the motion soft between wave fronts.
            Circle()
                .fill(color.opacity(reduceMotion ? 0.08 : 0.11))
                .frame(width: 16, height: 16)
                .scaleEffect(reduceMotion ? 1 : (expanded ? 1.08 : 0.94))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: state == .playing ? 0.82 : 1.05)
                        .repeatForever(autoreverses: true),
                    value: expanded
                )
            ring(delay: 0)
            ring(delay: state == .waking ? 0.62 : 0.82)
        }
        .frame(width: 46, height: 46)
        .drawingGroup()
        .onAppear { expanded = true }
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .stroke(color.opacity(reduceMotion ? 0.18 : (expanded ? 0 : 0.3)), lineWidth: 1.05)
            .scaleEffect(reduceMotion ? 1.08 : (expanded ? scale : 0.9))
            .animation(
                reduceMotion ? nil : .timingCurve(0.22, 0.72, 0.3, 1, duration: duration)
                    .repeatForever(autoreverses: false)
                    .delay(delay),
                value: expanded
            )
    }

    private var color: Color { state == .waking ? .orange : .white }
    private var duration: Double { state == .waking ? 1.7 : 2.15 }
    private var scale: CGFloat { state == .waking ? 1.85 : 1.58 }
}

/// Reports whether the hosting window is actually visible (not hidden or fully covered).
private struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onChange = { visible in DispatchQueue.main.async { self.visible = visible } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        // Selector-based observers are removed automatically when the view is deallocated.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            guard let window else { onChange?(false); return }
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            occlusionChanged()
        }

        @objc private func occlusionChanged() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}
