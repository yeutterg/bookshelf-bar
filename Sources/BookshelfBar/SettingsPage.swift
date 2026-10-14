import BookshelfBarCore
import KEFKit
import SwiftUI

struct SettingsPage: View {
    let speaker: SpeakerModel
    let back: () -> Void
    @AppStorage(VolumeCurve.gammaKey) private var gamma: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings", back: back)
            PageForm {
                Section {
                    Toggle(isOn: Binding(get: { speaker.deskMode }, set: { speaker.setDeskMode($0) })) {
                        Text("Desk Mode")
                        Text("Compensates for a desk in front of the speakers")
                    }
                    Toggle(isOn: Binding(get: { speaker.wallMode }, set: { speaker.setWallMode($0) })) {
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

                Section {
                    LabeledContent("Volume Curve") {
                        HStack(spacing: 10) {
                            Slider(value: Binding(get: { gamma }, set: { gamma = ($0 * 10).rounded() / 10 }),
                                   in: VolumeCurve.range)
                                .labelsHidden()
                            Text(gamma <= 1.0 ? "Native" : String(format: "γ %.2f", 1 / gamma))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                    CurvePreview(gamma: gamma)
                        .frame(height: 54)
                } header: {
                    Text("Volume")
                }

                Section("Tone") {
                    Picker("Bass Extension", selection: Binding(get: { speaker.bassExtension }, set: { speaker.setBassExtension($0) })) {
                        Text("Less").tag(BassExtension.less)
                        Text("Standard").tag(BassExtension.standard)
                        Text("Extra").tag(BassExtension.extra)
                    }
                    ValueSlider(title: "Treble", value: speaker.treble, range: -3...3, step: 0.25, commit: { speaker.setTreble($0) }) {
                        $0 == 0 ? "0 dB" : String(format: "%+.2f dB", $0)
                    }
                    ValueSlider(title: "Balance", value: Double(speaker.balance), range: -30...30, step: 1,
                                commit: { speaker.setBalance(Int($0)) }) {
                        $0 == 0 ? "Centre" : $0 < 0 ? "L \(Int(-$0))" : "R \(Int($0))"
                    }
                }

                if speaker.source == .usb {
                Section {
                    ValueSlider(title: "Speaker Level", value: Double(speaker.volume), range: 0...100, step: 1,
                                commit: { speaker.setVolume(Int($0)) }) { "\(Int($0))" }
                } header: {
                    Text("USB‑C")
                } footer: {
                    Text("On USB‑C, BookshelfBar's volume is the Mac's output volume, same as the macOS Sound control. This sets the speakers' own level underneath it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }

                Section("Power") {
                    Picker("Auto Standby", selection: Binding(get: { speaker.standbyMode }, set: { speaker.setStandbyMode($0) })) {
                        Text("After 20 min (ECO)").tag(StandbyMode.eco)
                        Text("After 30 min").tag(StandbyMode.thirtyMinutes)
                        Text("After 60 min").tag(StandbyMode.sixtyMinutes)
                        Text("Never").tag(StandbyMode.never)
                    }
                    Picker("Wake On", selection: Binding(get: { speaker.wakeUpSource }, set: { speaker.setWakeUpSource($0) })) {
                        Text("Default").tag(WakeUpSource.none)
                        Text("USB Audio").tag(WakeUpSource.usb)
                        Text("TV").tag(WakeUpSource.tv)
                        Text("Optical").tag(WakeUpSource.optical)
                        Text("Bluetooth").tag(WakeUpSource.bluetooth)
                        Text("Wi‑Fi").tag(WakeUpSource.wifi)
                    }
                    Picker("Maximum Volume", selection: Binding(get: { speaker.maximumVolume }, set: { speaker.setMaximumVolume($0) })) {
                        ForEach([40, 50, 60, 70, 80, 90], id: \.self) { Text("\($0)").tag($0) }
                        Text("No Limit").tag(100)
                    }
                }

                if speaker.lastError?.contains("signature") == true {
                    PasswordSection(speaker: speaker)
                }


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
                // No `step:` here: on macOS a stepped slider draws a tick per step, which turns into
                // a smudge at these step counts. Snap to the step in the binding instead.
                Slider(value: Binding(get: { draft ?? value }, set: { draft = ($0 / step).rounded() * step }), in: range) { editing in
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


/// Small plot of slider position (x) against native level (y) for the chosen gamma.
struct CurvePreview: View {
    let gamma: Double

    var body: some View {
        Canvas { context, size in
            var diagonal = Path()
            diagonal.move(to: CGPoint(x: 0, y: size.height))
            diagonal.addLine(to: CGPoint(x: size.width, y: 0))
            context.stroke(diagonal, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var curve = Path()
            for i in 0...60 {
                let x = Double(i) / 60
                let point = CGPoint(x: x * size.width, y: (1 - VolumeCurve.native(fromSlider: x, gamma: gamma)) * size.height)
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }
}
