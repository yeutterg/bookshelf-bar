import KEFBarCore
import KEFKit
import SwiftUI

struct MainPage: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HeroModule(speaker: speaker, smoothStart: smoothStart)
            switch speaker.connection {
            case .connected:
                VolumeModule(speaker: speaker)
                InputsModule(speaker: speaker)
                SmoothStartModule(smoothStart: smoothStart)
                SettingsLink(title: "Sound & Power Settings…", action: openSettings)
            case .searching, .connecting:
                EmptyView()
            case .unreachable(let reason):
                ManualConnectModule(speaker: speaker, reason: reason)
            }
        }
    }
}

// MARK: Hero

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

struct HeroModule: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart

    var body: some View {
        let state = speaker.visualState(smoothStart)
        ZStack(alignment: .topTrailing) {
            SpeakerArtwork(finish: speaker.finish, modelName: speaker.info?.modelName ?? "", state: state)
                .frame(width: 304 * 0.88)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if speaker.connection == .connected {
                Button { speaker.togglePower() } label: {
                    PaperIcon("icon-power").frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(speaker.isOn ? "Turn off" : "Turn on")
                .padding(10)
            }

            if let caption = caption(state) {
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(height: 220)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func caption(_ state: SpeakerState) -> String? {
        switch speaker.connection {
        case .searching: "Looking for speakers…"
        case .connecting(let name): "Connecting to \(name)…"
        case .unreachable: "Can't reach the speakers"
        case .connected: state == .waking ? "Waking…" : nil
        }
    }
}

/// The rendered speaker pair, styled per state.
struct SpeakerArtwork: View {
    let finish: KEFFinish
    let modelName: String
    let state: SpeakerState
    @State private var pulse = false

    private var imageName: String {
        switch (modelName, finish.artwork) {
        case ("LSX II", _): "speakers-lsxii-green"
        default: "speakers-graphite-grey"
        }
    }

    var body: some View {
        ZStack {
            if state == .playing {
                // Soft floor light under the pair.
                Ellipse()
                    .fill(Color(red: 1, green: 0.8, blue: 0.6).opacity(0.45))
                    .frame(width: 180, height: 26)
                    .blur(radius: 14)
                    .offset(y: 62)
            }
            image
                .resizable()
                .scaledToFit()
                .saturation(state == .standby || state == .offline ? 0.35 : state == .muted ? 0.7 : 1)
                .brightness(state == .standby || state == .offline ? -0.22 : state == .waking ? -0.12 : 0)
                .shadow(color: .black.opacity(0.35), radius: 7, y: 10)
            if state == .muted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
            }
        }
        .overlay {
            if state == .waking {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.orange.opacity(pulse ? 0.9 : 0.35), lineWidth: 1.5)
                    .shadow(color: .orange.opacity(pulse ? 0.6 : 0.2), radius: 12)
                    .padding(-8)
                    .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { pulse = true } }
                    .onDisappear { pulse = false }
            }
        }
        .animation(.smooth(duration: 0.4), value: state)
    }

    private var image: Image {
        if let url = Bundle.module.url(forResource: imageName, withExtension: "png"), let ns = NSImage(contentsOf: url) {
            return Image(nsImage: ns)
        }
        return Image(systemName: "hifispeaker.2")
    }
}

// MARK: Volume

struct VolumeModule: View {
    let speaker: SpeakerModel

    var body: some View {
        Module {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Volume").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(speaker.muted ? "Muted" : "\(speaker.volume)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                CapsuleSlider(value: Binding(get: { Double(speaker.volume) / 100 },
                                             set: { speaker.setVolume(Int(($0 * 100).rounded())) }),
                              muted: speaker.muted,
                              onIconTap: speaker.toggleMute)
            }
        }
    }
}

/// Control Center–style thick slider with the speaker glyph inside; tap the glyph to mute.
struct CapsuleSlider: View {
    @Binding var value: Double
    var muted: Bool
    var onIconTap: () -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.18))
                Capsule()
                    .fill(.white.opacity(muted ? 0.45 : 0.94))
                    .frame(width: max(28, w * value))
                PaperIcon(muted ? "icon-volume-muted" : "icon-volume")
                    .foregroundStyle(Color(red: 0.227, green: 0.227, blue: 0.251))
                    .frame(width: 36, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onIconTap)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard g.startLocation.x > 28 || abs(g.translation.width) > 2 else { return }
                value = min(max(g.location.x / w, 0), 1)
            })
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100))")
        .accessibilityAdjustableAction { dir in
            value = min(max(value + (dir == .increment ? 0.02 : -0.02), 0), 1)
        }
    }
}

// MARK: Inputs

struct InputsModule: View {
    let speaker: SpeakerModel

    var body: some View {
        let inputs = PhysicalSource.inputs(forModel: speaker.info?.modelName ?? "LSX II LT")
        Module(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Input").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
                HStack(spacing: 0) {
                    ForEach(Array(inputs.enumerated()), id: \.element) { i, input in
                        if i > 0 { Spacer(minLength: 0) }
                        InputButton(input: input, compact: inputs.count > 5,
                                    selected: speaker.isOn && speaker.source == input) {
                            speaker.setSource(input)
                        }
                        .frame(width: inputs.count > 5 ? 46 : 56)
                    }
                }
            }
        }
    }
}

struct InputButton: View {
    let input: PhysicalSource
    let compact: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                PaperIcon(input.icon)
                    .frame(width: compact ? 38 : 42, height: compact ? 38 : 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(selected ? .accentColor : nil)
            .glassEffect(selected ? .regular.tint(.accentColor) : .regular, in: .circle)
            Text(compact ? input.shortLabel : input.label)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
        }
    }
}

extension PhysicalSource {
    var label: String {
        switch self {
        case .wifi: "Wi‑Fi"
        case .bluetooth: "Bluetooth"
        case .tv: "TV"
        case .optical: "Optical"
        case .usb: "USB‑C"
        case .analog: "AUX"
        case .coaxial: "Coaxial"
        case .standby: "Off"
        case .powerOn: "On"
        }
    }
    var shortLabel: String { self == .bluetooth ? "BT" : label }
    var icon: String {
        switch self {
        case .wifi: "icon-wifi"
        case .bluetooth: "icon-bluetooth"
        case .tv: "icon-tv"
        case .optical: "icon-optical"
        case .usb: "icon-usb"
        case .analog, .coaxial: "icon-aux"
        case .standby, .powerOn: "icon-power"
        }
    }
}

// MARK: Smooth Start

struct SmoothStartModule: View {
    @Bindable var smoothStart: SmoothStart

    var body: some View {
        Module(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 12)) {
            HStack(spacing: 12) {
                PaperIcon("icon-ramp")
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Smooth Start").font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Smooth Start", isOn: $smoothStart.enabled).labelsHidden().toggleStyle(.switch)
            }
        }
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

struct SettingsLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                PaperIcon("icon-chevron-right").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Manual connect

struct ManualConnectModule: View {
    let speaker: SpeakerModel
    let reason: String
    @State private var host = ""

    var body: some View {
        Module {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speakers not found").font(.system(size: 13, weight: .semibold))
                Text("Make sure they're on the same network as this Mac (guest networks block discovery), or enter their IP address.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("192.168.1.20", text: $host).textFieldStyle(.roundedBorder)
                    Button("Connect") { Task { await speaker.connect(host: host, remember: true) } }
                        .buttonStyle(.glassProminent)
                        .disabled(host.isEmpty)
                }
            }
        }
    }
}
