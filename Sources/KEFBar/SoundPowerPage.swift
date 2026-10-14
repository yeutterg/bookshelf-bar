import KEFBarCore
import KEFKit
import SwiftUI

struct SoundPowerPage: View {
    let speaker: SpeakerModel
    let back: () -> Void
    let about: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            PageHeader(title: "Sound & Power",
                       subtitle: speaker.profileName.isEmpty ? nil : "EQ profile “\(speaker.profileName)”",
                       back: back)
            HStack(spacing: 10) {
                PlacementTile(title: "Desk", isOn: speaker.deskMode, wall: false, set: speaker.setDeskMode)
                PlacementTile(title: "Wall", isOn: speaker.wallMode, wall: true, set: speaker.setWallMode)
            }
            ToneModule(speaker: speaker)
            PowerModule(speaker: speaker)
            if speaker.lastError?.contains("signature") == true {
                PasswordModule(speaker: speaker)
            }
            Module(padding: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) {
                SettingsLink(title: "About", action: about).padding(.vertical, 4).padding(.horizontal, 4)
            }
        }
        .task { await speaker.refreshSettings() }
    }
}

struct PlacementTile: View {
    let title: String
    let isOn: Bool
    let wall: Bool
    let set: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: wall ? .trailing : .bottom) {
                SingleSpeaker()
                    .frame(width: 52, height: 72)
                    .opacity(isOn ? 1 : 0.7)
                    .frame(maxWidth: .infinity)
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: wall ? 3 : nil, height: wall ? nil : 2)
                    .padding(wall ? .trailing : .horizontal, wall ? 14 : 8)
            }
            .frame(height: 80)
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle(title, isOn: Binding(get: { isOn }, set: set)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .glassEffect(isOn ? .regular.tint(.accentColor.opacity(0.35)) : .regular, in: .rect(cornerRadius: 20))
    }
}

/// One speaker cropped out of the pair render.
struct SingleSpeaker: View {
    var body: some View {
        GeometryReader { geo in
            if let url = Bundle.module.url(forResource: "speakers-graphite-grey", withExtension: "png"), let ns = NSImage(contentsOf: url) {
                Image(nsImage: ns)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width * 2.6, height: geo.size.height)
                    .offset(x: -geo.size.width * 0.33)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                    .clipped()
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 5)
            }
        }
    }
}

struct ToneModule: View {
    let speaker: SpeakerModel

    var body: some View {
        Module(padding: EdgeInsets(top: 12, leading: 14, bottom: 16, trailing: 14)) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bass Extension").font(.system(size: 13, weight: .semibold))
                    Picker("Bass Extension", selection: Binding(get: { speaker.bassExtension }, set: speaker.setBassExtension)) {
                        Text("Less").tag(BassExtension.less)
                        Text("Standard").tag(BassExtension.standard)
                        Text("Extra").tag(BassExtension.extra)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                LabeledSlider(title: "Treble", value: speaker.treble, range: -3...3, step: 0.25,
                              display: { String(format: "%+.2f dB", $0).replacingOccurrences(of: "+0.00", with: "0") },
                              commit: speaker.setTreble)
                LabeledSlider(title: "Balance", value: Double(speaker.balance), range: -30...30, step: 1,
                              display: { $0 == 0 ? "Centre" : $0 < 0 ? "L \(Int(-$0))" : "R \(Int($0))" },
                              commit: { speaker.setBalance(Int($0)) })
            }
        }
    }
}

/// Slider that writes to the speaker when the drag ends (DSP writes are signed and relatively slow).
struct LabeledSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String
    let commit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(display(draft ?? value)).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: range, step: step) { editing in
                if !editing, let d = draft { commit(d); draft = nil }
            }
            .labelsHidden()
        }
    }
}

struct PowerModule: View {
    let speaker: SpeakerModel

    var body: some View {
        Module(padding: EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14)) {
            VStack(spacing: 0) {
                MenuRow(title: "Auto Standby", selection: Binding(get: { speaker.standbyMode }, set: speaker.setStandbyMode),
                        options: StandbyMode.allCases) { mode in
                    switch mode {
                    case .eco: "20 min (ECO)"
                    case .thirtyMinutes: "30 min"
                    case .sixtyMinutes: "60 min"
                    case .never: "Never"
                    }
                }
                Divider().opacity(0.5)
                MenuRow(title: "Wake On", selection: Binding(get: { speaker.wakeUpSource }, set: speaker.setWakeUpSource),
                        options: WakeUpSource.allCases) { source in
                    switch source {
                    case .none: "Default"
                    case .usb: "USB Audio"
                    case .tv: "TV"
                    case .optical: "Optical"
                    case .bluetooth: "Bluetooth"
                    case .wifi: "Wi‑Fi"
                    }
                }
                Divider().opacity(0.5)
                MenuRow(title: "Maximum Volume", selection: Binding(get: { speaker.maximumVolume }, set: speaker.setMaximumVolume),
                        options: [40, 50, 60, 70, 80, 90, 100]) { $0 == 100 ? "No limit" : "\($0)" }
            }
        }
    }
}

struct MenuRow<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .frame(height: 40)
    }
}

struct PasswordModule: View {
    let speaker: SpeakerModel
    @State private var password = ""

    var body: some View {
        Module {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speaker password required").font(.system(size: 13, weight: .semibold))
                Text("A password was set on the speaker's web page. Changes to sound and power settings need it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    Button("Save") { speaker.setPassword(password) }.buttonStyle(.glassProminent)
                }
            }
        }
    }
}
