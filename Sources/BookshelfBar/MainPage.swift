import BookshelfBarCore
import KEFKit
import SwiftUI

struct MainPage: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart
    let keepAwake: KeepAwake
    let openSettings: () -> Void
    let openAbout: () -> Void

    var body: some View {
        // Keep the established System Settings-style structure. The artwork carries the new
        // character and motion without redesigning the controls around it.
        PageForm {
            Section {
                PowerRow(speaker: speaker, smoothStart: smoothStart)
                if speaker.connection == .connected {
                    VolumeRow(speaker: speaker, smoothStart: smoothStart)
                }
                SpeakerArtwork(finish: speaker.finish, state: speaker.visualState(smoothStart))
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
            } header: {
                if let name = speaker.info?.name, !name.isEmpty { Text(name) }
            }

            switch speaker.connection {
            case .connected:
                Section("Input") { InputRows(speaker: speaker) }
                Section("Automation") {
                    SmoothStartRow(smoothStart: smoothStart)
                    KeepAwakeRow(keepAwake: keepAwake)
                }
                Section("Settings") {
                    DisclosureRow(title: "Sound", systemImage: "slider.horizontal.3", action: openSettings)
                    DisclosureRow(title: "About", systemImage: "info.circle", action: openAbout)
                    QuitRow()
                }
            case .unreachable:
                if speaker.localNetworkDenied {
                    LocalNetworkSection(speaker: speaker)
                } else {
                    Section { ManualConnectRows(speaker: speaker) }
                }
            case .searching, .connecting:
                EmptyView()
            }
        }
    }
}

// MARK: Header and artwork

enum SpeakerState: Equatable { case offline, reconnecting, standby, waking, on, playing, muted }

extension SpeakerModel {
    @MainActor func visualState(_ smoothStart: SmoothStart) -> SpeakerState {
        guard connection == .connected else { return .offline }
        if reconnecting { return .reconnecting }
        if smoothStart.phase != .idle { return .waking }
        if !isOn { return .standby }
        if source == .usb {
            let macVolumeIsZero = smoothStart.macVolume.map { $0 <= 0.001 } ?? false
            if muted || smoothStart.macMuted || macVolumeIsZero { return .muted }
            // CoreAudio posts this transition for us. It keeps the idle path timer-free and
            // avoids pretending that an awake speaker is necessarily playing audio.
            return smoothStart.usbRunning ? .playing : .on
        }
        if muted || volume == 0 { return .muted }
        // The KEF event API does not expose an equivalent activity signal for every network
        // input. Stay honestly still instead of inventing playback from the power state.
        return .on
    }
}

/// Power switch with the current transient status underneath, like the built-in menu extras.
struct PowerRow: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart

    var body: some View {
        if speaker.connection == .connected {
            Toggle(isOn: Binding(get: { speaker.isOn }, set: { _ in speaker.togglePower() })) {
                Label {
                    Text("Power")
                    if let status {
                        HStack(spacing: 6) {
                            Text(status)
                            ProgressView().controlSize(.mini)
                        }.lineLimit(1)
                    }
                } icon: {
                    Image(systemName: "power")
                }
            }
            .toggleStyle(.switch)
            .disabled(speaker.reconnecting)
        } else {
            HStack(spacing: 8) {
                if case .unreachable = speaker.connection {} else { ProgressView().controlSize(.small) }
                Text(offlineStatus).foregroundStyle(.secondary)
            }
        }
    }

    private var status: String? {
        if speaker.reconnecting { return "Reconnecting…" }
        if smoothStart.phase != .idle { return "Speakers powering up" }
        if smoothStart.safetyFailure { return "Volume held muted — check Sound settings" }
        return nil
    }

    private var offlineStatus: String {
        switch speaker.connection {
        case .searching: "Looking for speakers…"
        case .connecting: "Connecting…"
        case .unreachable: "Not reachable"
        case .connected: ""
        }
    }
}

// MARK: Volume

struct VolumeRow: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart
    @AppStorage(VolumeCurve.gammaKey) private var gamma: Double = 1

    /// On USB‑C the slider is the Mac's output volume, the same value the macOS Sound control
    /// and volume keys change. On the speaker's other inputs it's the speaker's own volume.
    private var usesMacVolume: Bool { speaker.source == .usb && smoothStart.macVolume != nil }
    private var muted: Bool { usesMacVolume ? smoothStart.macMuted : speaker.muted }
    private var g: Double { min(max(gamma, VolumeCurve.range.lowerBound), VolumeCurve.range.upperBound) }

    /// Native value (0…1): macOS scalar on USB‑C, speaker volume / 100 otherwise.
    private var native: Double {
        usesMacVolume ? Double(smoothStart.macVolume ?? 0) : Double(speaker.volume) / 100
    }
    private var value: Double { VolumeCurve.slider(fromNative: native, gamma: g) * 100 }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { toggleMute() }) {
                PaperIcon(muted ? "icon-volume-muted" : "icon-volume")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(muted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { value }, set: { set($0) }), in: 0...100) { Text("Volume") }
                .labelsHidden()
            Text("\(Int(value.rounded()))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
        .disabled(!speaker.isOn)
    }

    private func set(_ v: Double) {
        let n = VolumeCurve.native(fromSlider: v / 100, gamma: g)
        if usesMacVolume { smoothStart.setMacVolume(Float(n)) } else { speaker.setVolume(Int((n * 100).rounded())) }
    }

    private func toggleMute() {
        if usesMacVolume { smoothStart.toggleMacMute() } else { speaker.toggleMute() }
    }
}

// MARK: Input

/// One row per physical input with a checkmark on the active one, like the Sound menu extra.
struct InputRows: View {
    let speaker: SpeakerModel

    var body: some View {
        ForEach(PhysicalSource.inputs(forModel: speaker.info?.modelName ?? "LSX II LT"), id: \.self) { input in
            let selected = speaker.isOn && speaker.source == input
            Button { speaker.setSource(input) } label: {
                HStack {
                    Label {
                        Text(input.label)
                    } icon: {
                        PaperIcon(input.icon).foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

extension PhysicalSource {
    var label: String {
        switch self {
        case .wifi: "Wi‑Fi"
        case .bluetooth: "Bluetooth"
        case .tv: "TV (HDMI eARC)"
        case .optical: "Optical"
        case .usb: "USB‑C"
        case .analog: "AUX"
        case .coaxial: "Coaxial"
        case .standby: "Standby"
        case .powerOn: "On"
        }
    }

    /// Icons from the Paper design (Resources/icon-*.svg).
    var icon: String {
        switch self {
        case .wifi: "icon-wifi"
        case .bluetooth: "icon-bluetooth"
        case .tv: "icon-tv"
        case .optical: "icon-optical"
        case .usb: "icon-usb"
        case .analog, .coaxial, .standby, .powerOn: "icon-aux"
        }
    }

}

// MARK: Smooth Start

struct SmoothStartRow: View {
    @Bindable var smoothStart: SmoothStart

    var body: some View {
        Toggle(isOn: $smoothStart.enabled) {
            Label {
                Text("Smooth Start")
                Text(subtitle).lineLimit(1)
            } icon: {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
            }
        }
        .toggleStyle(.switch)
    }

    private var subtitle: String {
        switch smoothStart.phase {
        case .waking: return "Speakers powering up"
        case .settling: return "Ramping volume up…"
        case .idle: return "Ramps volume up while waking"
        }
    }
}

struct KeepAwakeRow: View {
    @Bindable var keepAwake: KeepAwake

    var body: some View {
        Toggle(isOn: $keepAwake.enabled) {
            Label {
                Text("Keep Awake With Screen")
                Text("Standby when the screen turns off").lineLimit(1)
            } icon: {
                Image(systemName: "display")
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: Manual connect

struct ManualConnectRows: View {
    let speaker: SpeakerModel
    @State private var host = ""

    var body: some View {
        Text("Make sure the speakers are on the same network as this Mac. Guest networks can block discovery.")
            .font(.callout)
            .foregroundStyle(.secondary)
        TextField("IP address", text: $host, prompt: Text("192.168.1.20"))
            .onSubmit(connect)
        Button("Connect", action: { connect() })
            .disabled(host.isEmpty)
    }

    private func connect() {
        Task { await speaker.connect(host: host, remember: true) }
    }
}



/// Quit as the last row of the main page's Settings group.
struct QuitRow: View {
    var body: some View {
        Button { NSApp.terminate(nil) } label: {
            HStack {
                Label("Quit \(AppInfo.name)", systemImage: "power")
                Spacer()
                Text("⌘Q").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
    }
}
