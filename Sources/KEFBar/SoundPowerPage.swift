import KEFBarCore
import KEFKit
import SwiftUI

struct SoundPowerPage: View {
    let speaker: SpeakerModel
    let back: () -> Void
    let about: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Sound & Power", back: back)
            PageForm {
                Section {
                    Toggle(isOn: Binding(get: { speaker.deskMode }, set: speaker.setDeskMode)) {
                        Text("Desk Mode")
                        Text("Compensates for a desk in front of the speakers")
                    }
                    Toggle(isOn: Binding(get: { speaker.wallMode }, set: speaker.setWallMode)) {
                        Text("Wall Mode")
                        Text("Compensates for a wall behind the speakers")
                    }
                } header: {
                    Text("Placement")
                } footer: {
                    if !speaker.profileName.isEmpty {
                        Text("EQ profile “\(speaker.profileName)”").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Tone") {
                    Picker("Bass Extension", selection: Binding(get: { speaker.bassExtension }, set: speaker.setBassExtension)) {
                        Text("Less").tag(BassExtension.less)
                        Text("Standard").tag(BassExtension.standard)
                        Text("Extra").tag(BassExtension.extra)
                    }
                    ValueSlider(title: "Treble", value: speaker.treble, range: -3...3, step: 0.25, commit: speaker.setTreble) {
                        $0 == 0 ? "0 dB" : String(format: "%+.2f dB", $0)
                    }
                    ValueSlider(title: "Balance", value: Double(speaker.balance), range: -30...30, step: 1,
                                commit: { speaker.setBalance(Int($0)) }) {
                        $0 == 0 ? "Centre" : $0 < 0 ? "L \(Int(-$0))" : "R \(Int($0))"
                    }
                }

                Section("Power") {
                    Picker("Auto Standby", selection: Binding(get: { speaker.standbyMode }, set: speaker.setStandbyMode)) {
                        Text("After 20 min (ECO)").tag(StandbyMode.eco)
                        Text("After 30 min").tag(StandbyMode.thirtyMinutes)
                        Text("After 60 min").tag(StandbyMode.sixtyMinutes)
                        Text("Never").tag(StandbyMode.never)
                    }
                    Picker("Wake On", selection: Binding(get: { speaker.wakeUpSource }, set: speaker.setWakeUpSource)) {
                        Text("Default").tag(WakeUpSource.none)
                        Text("USB Audio").tag(WakeUpSource.usb)
                        Text("TV").tag(WakeUpSource.tv)
                        Text("Optical").tag(WakeUpSource.optical)
                        Text("Bluetooth").tag(WakeUpSource.bluetooth)
                        Text("Wi‑Fi").tag(WakeUpSource.wifi)
                    }
                    Picker("Maximum Volume", selection: Binding(get: { speaker.maximumVolume }, set: speaker.setMaximumVolume)) {
                        ForEach([40, 50, 60, 70, 80, 90], id: \.self) { Text("\($0)").tag($0) }
                        Text("No Limit").tag(100)
                    }
                }

                if speaker.lastError?.contains("signature") == true {
                    PasswordSection(speaker: speaker)
                }

                Section { DisclosureRow(title: "About", systemImage: "info.circle", action: about) }
            }
        }
        // Re-run once connected: the page can open before the first connection finishes.
        .task(id: speaker.connection == .connected) {
            if speaker.connection == .connected { await speaker.refreshSettings() }
        }
    }
}

/// Labelled slider that writes when the drag ends (DSP writes are signed and comparatively slow).
struct ValueSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let commit: (Double) -> Void
    let format: (Double) -> String
    @State private var draft: Double?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: range, step: step) { editing in
                    if !editing, let d = draft { commit(d); draft = nil }
                }
                .labelsHidden()
                Text(format(draft ?? value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }
}

struct PasswordSection: View {
    let speaker: SpeakerModel
    @State private var password = ""

    var body: some View {
        Section {
            SecureField("Password", text: $password)
                .onSubmit { speaker.setPassword(password) }
            Button("Save Password") { speaker.setPassword(password) }
        } header: {
            Text("Speaker Password")
        } footer: {
            Text("A password was set on the speaker's web page. Sound and power changes need it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
