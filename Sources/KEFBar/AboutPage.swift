import AppKit
import KEFBarCore
import KEFKit
import SwiftUI

struct AboutPage: View {
    let speaker: SpeakerModel
    let back: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            PageHeader(title: "About", back: back)
            Module(padding: EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 8)) {
                VStack(spacing: 0) {
                    let rows = self.rows
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        CopyableRow(title: row.0, value: row.1)
                        if i < rows.count - 1 { Divider().opacity(0.5) }
                    }
                }
            }
            HStack {
                Text("KEF Bar \(Bundle.main.appVersion)").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit KEF Bar") { NSApp.terminate(nil) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding(.horizontal, 6)
        }
    }

    private var rows: [(String, String)] {
        guard let info = speaker.info else { return [("Network", speaker.host ?? "—")] }
        var rows = [("Name", info.name), ("Model", info.modelName),
                    ("Primary serial", info.serialNumber)]
        if !info.serialNumberSecondary.isEmpty { rows.append(("Secondary serial", info.serialNumberSecondary)) }
        rows.append(("Firmware", info.firmware.components(separatedBy: ".0x").first ?? info.firmware))
        if let host = speaker.host { rows.append(("IP address", host)) }
        if !info.mac.isEmpty { rows.append(("MAC address", info.mac)) }
        return rows
    }
}

/// A label/value row. Hovering reveals a copy button; clicking anywhere on the row copies the value.
struct CopyableRow: View {
    let title: String
    let value: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Color.green : .secondary)
                .frame(width: 22, height: 22)
                .glassEffect(.regular.interactive(), in: .circle)
                .opacity(hovering || copied ? 1 : 0)
                .help("Copy \(title.lowercased())")
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { copy() }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityAction(named: "Copy") { copy() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

extension Bundle {
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
