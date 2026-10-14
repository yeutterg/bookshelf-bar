import AppKit
import BookshelfBarCore
import SwiftUI

enum AppInfo {
    static let name = "BookshelfBar"

    /// The app was called KEF Bar (bundle id com.github.yeutterg.kefbar). Carry its settings
    /// over once: chosen speaker, remembered address, volume, Smooth Start options.
    static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromKEFBar"),
              let old = defaults.persistentDomain(forName: "com.github.yeutterg.kefbar") else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "migratedFromKEFBar")
    }
}

/// Owns the long-lived models. One instance for the app's lifetime.
@MainActor
final class AppState {
    static let shared = AppState()
    let speaker = SpeakerModel()
    lazy var smoothStart = SmoothStart(speaker: speaker)
    lazy var keepAwake = KeepAwake(speaker: speaker, smoothStart: smoothStart)
    lazy var firmware = FirmwareUpdater(speaker: speaker)

    func start() {
        AppInfo.migrateLegacyDefaults()
        speaker.start()
        smoothStart.start()
        keepAwake.start()
        listenForCommands()
        Task { @MainActor in
            for _ in 0..<30 where self.speaker.connection != .connected { try? await Task.sleep(for: .seconds(1)) }
            await self.firmware.refresh()
        }
        watchLocalNetworkPermission()
    }

    private var askedForLocalNetwork = false

    /// macOS shows its Local Network prompt only once per app and offers no API to show it again.
    /// When access turns out to be blocked, ask with our own alert instead, pointing at the
    /// exact Settings pane. Once per launch, so it never nags.
    private func watchLocalNetworkPermission() {
        withObservationTracking {
            _ = speaker.localNetworkDenied
        } onChange: {
            Task { @MainActor in
                let state = AppState.shared
                if state.speaker.localNetworkDenied {
                    // The approval is tied to the app's binary. If the binary on disk was replaced
                    // since launch (an update or rebuild), this process no longer matches it:
                    // relaunch from the new binary instead of asking the user for nothing.
                    if state.binaryReplacedSinceLaunch {
                        state.relaunch()
                    } else if !state.askedForLocalNetwork {
                        state.askedForLocalNetwork = true
                        // After an install or update macOS takes a few seconds to re-apply an
                        // existing approval; only ask if it's still blocked after that.
                        try? await Task.sleep(for: .seconds(15))
                        if state.speaker.localNetworkDenied { state.showLocalNetworkAlert() } else { state.askedForLocalNetwork = false }
                    }
                }
                state.watchLocalNetworkPermission()
            }
        }
    }

    private let launchDate = Date()

    private var binaryReplacedSinceLaunch: Bool {
        guard let url = Bundle.main.executableURL,
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return modified > launchDate
    }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private var permissionWindow: NSWindow?

    /// Non-modal on purpose: a modal alert would block the main thread, and with it the
    /// reconnect checks that notice when access is turned on.
    private func showLocalNetworkAlert() {
        if let w = permissionWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let view = LocalNetworkPrompt(
            open: { NSWorkspace.shared.open(SpeakerModel.localNetworkSettingsURL) },
            dismiss: { [weak self] in self?.permissionWindow?.close(); self?.permissionWindow = nil })
        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        permissionWindow = window
        // Close it automatically once access works.
        Task { @MainActor in
            while self.speaker.localNetworkDenied, self.permissionWindow != nil { try? await Task.sleep(for: .seconds(1)) }
            self.permissionWindow?.close()
            self.permissionWindow = nil
        }
    }

    /// Local automation hook (Shortcuts, scripts, tests): post the distributed notification
    /// `com.github.yeutterg.bookshelfbar.power` with object "on", "off" or "toggle". Goes through the same
    /// code path as the power switch, including Smooth Start.
    private func listenForCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.github.yeutterg.bookshelfbar.power"), object: nil, queue: .main) { note in
            let command = note.object as? String
            MainActor.assumeIsolated {
                let speaker = AppState.shared.speaker
                switch command {
                case "on": if !speaker.isOn { speaker.togglePower() }
                case "off": if speaker.isOn { speaker.togglePower() }
                default: speaker.togglePower()
                }
            }
        }
    }
}

struct BookshelfBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private let state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            RootView(speaker: state.speaker, smoothStart: state.smoothStart, keepAwake: state.keepAwake, firmware: state.firmware)
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

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.smoothStart.prepareForQuit() }
    }

    @MainActor private func showPreview() {
        let state = AppState.shared
        // `--page settings|setup` opens the preview on a specific page.
        let page = CommandLine.arguments.firstIndex(of: "--page").flatMap { i in
            i + 1 < CommandLine.arguments.count ? Page(rawValue: CommandLine.arguments[i + 1]) : nil
        } ?? .main
        let host = NSHostingView(rootView: RootView(speaker: state.speaker, smoothStart: state.smoothStart, keepAwake: state.keepAwake, firmware: state.firmware, page: page))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 364, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "BookshelfBar Preview"
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

/// Native-looking permission request, shown when macOS blocks local network access.
struct LocalNetworkPrompt: View {
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("BookshelfBar needs Local Network access").font(.headline)
            Text("macOS is blocking BookshelfBar from reaching your speakers. Turn on BookshelfBar in Local Network settings. This window closes by itself once it's allowed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now", action: dismiss)
                Button("Open Local Network Settings", action: open)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--artwork-snapshot") {
    guard index + 1 < CommandLine.arguments.count else {
        fatalError("--artwork-snapshot requires an output PNG path")
    }
    try writeArtworkSnapshot(to: CommandLine.arguments[index + 1])
} else {
    BookshelfBarApp.main()
}
