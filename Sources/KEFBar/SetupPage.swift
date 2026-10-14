import KEFBarCore
import KEFKit
import SwiftUI

/// First run (and "Change Speakers…"): pick which pair this Mac controls. KEF speakers have no
/// pairing protocol of their own (the local API is open), so "pairing" here means choosing a
/// pair, remembering it by its permanent kefId, and verifying it answers.
struct SetupPage: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart
    @State private var identifying: String?
    @State private var showManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose Your Speakers").font(.headline)
                Text("Speakers set up in the KEF Connect app appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            PageForm { form }
        }
    }

    @ViewBuilder private var form: some View {
            Section {
                if speaker.speakers.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for speakers on your network…").foregroundStyle(.secondary)
                    }
                }
                ForEach(speaker.speakers) { info in
                    SpeakerRow(info: info,
                               onUSB: matchesUSB(info),
                               identifying: identifying == info.kefId,
                               identify: { identify(info) },
                               connect: { Task { await speaker.pair(info) } })
                }
            } header: {
                Text("On This Network")
            } footer: {
                if !speaker.speakers.isEmpty {
                    Text("Identify wakes a pair for a few seconds so you can hear which one it is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup("Enter IP Address", isExpanded: $showManual) {
                    ManualConnectRows(speaker: speaker)
                }
            }
    }

    /// The USB device only tells us its model, so we can point at a pair only when exactly one
    /// speaker on the network is that model.
    private func matchesUSB(_ info: KEFSpeakerInfo) -> Bool {
        guard let usb = smoothStart.usbDeviceName, usb == info.modelName else { return false }
        return speaker.speakers.filter { $0.modelName == usb }.count == 1
    }

    private func identify(_ info: KEFSpeakerInfo) {
        identifying = info.kefId
        Task {
            await speaker.identify(info)
            identifying = nil
        }
    }
}

struct SpeakerRow: View {
    let info: KEFSpeakerInfo
    let onUSB: Bool
    let identifying: Bool
    let identify: () -> Void
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: {
                Image(systemName: "hifispeaker.2.fill").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(action: identify) {
                    Text(identifying ? "Identifying…" : "Identify")
                }
                .disabled(identifying)
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [info.modelName]
        if onUSB { parts.append("Connected to this Mac") }
        return parts.joined(separator: " · ")
    }
}
