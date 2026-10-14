import AppKit
import KEFBarCore
import SwiftUI

/// Owns the long-lived models. One instance for the app's lifetime.
@MainActor
final class AppState {
    static let shared = AppState()
    let speaker = SpeakerModel()
    lazy var smoothStart = SmoothStart(speaker: speaker)

    func start() {
        speaker.start()
        smoothStart.start()
    }
}

struct KEFBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private let state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            RootView(speaker: state.speaker, smoothStart: state.smoothStart)
        } label: {
            MenuBarIcon(speaker: state.speaker, smoothStart: state.smoothStart)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            AppState.shared.start()
            // `--preview` shows the popover content in a normal window, for screenshots and development.
            if CommandLine.arguments.contains("--preview") { showPreview() }
        }
    }

    @MainActor private func showPreview() {
        let state = AppState.shared
        let host = NSHostingView(rootView: RootView(speaker: state.speaker, smoothStart: state.smoothStart)
            .padding(12)
            .background(.ultraThinMaterial))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 364, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "KEF Bar Preview"
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        previewWindow = window

        // `--snapshot <path.png>`: write the preview to disk after it settles (development aid).
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

KEFBarApp.main()
