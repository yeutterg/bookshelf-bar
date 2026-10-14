import KEFBarCore
import KEFKit
import SwiftUI

struct MainPage: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart
    let openSettings: () -> Void

    var body: some View {
        PageForm {
            Section {
                HeaderRow(speaker: speaker, smoothStart: smoothStart)
                SpeakerArtwork(modelName: speaker.info?.modelName ?? "", state: speaker.visualState(smoothStart))
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
            }

            switch speaker.connection {
            case .connected:
                Section("Volume") { VolumeRow(speaker: speaker) }
                Section("Input") { InputRows(speaker: speaker) }
                Section { SmoothStartRow(smoothStart: smoothStart) }
                Section { DisclosureRow(title: "Sound & Power", systemImage: "slider.horizontal.3", action: openSettings) }
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

enum SpeakerState { case offline, standby, waking, playing, muted }

extension SpeakerModel {
    @MainActor func visualState(_ smoothStart: SmoothStart) -> SpeakerState {
        guard connection == .connected else { return .offline }
        if smoothStart.phase != .idle { return .waking }
        if !isOn { return .standby }
        if muted { return .muted }
        return .playing
    }
}

/// Name and status with a power switch, like the Wi‑Fi and Bluetooth menu extras.
struct HeaderRow: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.info?.name ?? "KEF Speakers").font(.headline)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if speaker.connection == .connected {
                Toggle("Power", isOn: Binding(get: { speaker.isOn }, set: { _ in speaker.togglePower() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            } else if case .unreachable = speaker.connection {
                EmptyView()
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var status: String {
        switch speaker.connection {
        case .searching: return "Looking for speakers…"
        case .connecting: return "Connecting…"
        case .unreachable: return "Not found"
        case .connected:
            if smoothStart.phase != .idle { return "Waking…" }
            guard speaker.isOn else { return "Standby" }
            return speaker.muted ? "\(speaker.source.label) · Muted" : speaker.source.label
        }
    }
}

/// The rendered speaker pair: dimmed in standby, pulsing while waking, full colour when on.
struct SpeakerArtwork: View {
    let modelName: String
    let state: SpeakerState
    @State private var pulse = false

    var body: some View {
        ZStack {
            image
                .resizable()
                .scaledToFit()
                .saturation(state == .standby || state == .offline ? 0.35 : 1)
                .brightness(state == .standby || state == .offline ? -0.2 : 0)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 8)
                .opacity(state == .waking && pulse ? 0.55 : 1)
            if state == .muted {
                Image(systemName: "speaker.slash.fill")
                    .font(.title3)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }
        }
        .animation(.smooth, value: state)
        .onChange(of: state, initial: true) { _, new in
            if new == .waking {
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true }
            } else {
                withAnimation(.smooth) { pulse = false }
            }
        }
        .accessibilityHidden(true)
    }

    private var image: Image {
        let name = modelName == "LSX II" ? "speakers-lsxii-green" : "speakers-graphite-grey"
        if let url = Bundle.module.url(forResource: name, withExtension: "png"), let ns = NSImage(contentsOf: url) {
            return Image(nsImage: ns)
        }
        return Image(systemName: "hifispeaker.2")
    }
}

// MARK: Volume

struct VolumeRow: View {
    let speaker: SpeakerModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: speaker.toggleMute) {
                PaperIcon(speaker.muted ? "icon-volume-muted" : "icon-volume")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(speaker.muted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(speaker.volume) }, set: { speaker.setVolume(Int($0.rounded())) }),
                   in: 0...100) { Text("Volume") }
                .labelsHidden()
            Text("\(speaker.volume)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
        .disabled(!speaker.isOn)
    }
}

// MARK: Input

/// One row per physical input with a checkmark on the active one, like the output list in the
/// Sound menu extra.
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
                Text(subtitle)
            } icon: {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
            }
        }
        .toggleStyle(.switch)
    }

    private var subtitle: String {
        if !smoothStart.usbPresent { return "Connect the speakers over USB‑C" }
        switch smoothStart.phase {
        case .idle: return "Ramps volume up while waking"
        case .waking: return "Waking speakers, holding audio…"
        case .settling: return "Restoring volume…"
        }
    }
}

// MARK: Local Network permission

struct LocalNetworkSection: View {
    let speaker: SpeakerModel

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can't Reach the Speakers")
                    Text("Make sure KEF Bar is allowed in Privacy & Security › Local Network, and that the speakers are on and on the same network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "network").foregroundStyle(.orange)
            }
            HStack {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Try Again", action: speaker.retry)
            }
        }
        Section { DisclosureGroup("Enter IP Address") { ManualConnectRows(speaker: speaker) } }
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
        Button("Connect", action: connect)
            .disabled(host.isEmpty)
    }

    private func connect() {
        Task { await speaker.connect(host: host, remember: true) }
    }
}
