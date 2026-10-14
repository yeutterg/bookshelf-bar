import AppKit
import BookshelfBarCore
import SwiftUI

struct AboutPage: View {
    let speaker: SpeakerModel
    let firmware: FirmwareUpdater
    let back: () -> Void
    let changeSpeakers: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "About", back: back)
            PageForm {
                Section {
                    ForEach(rows, id: \.0) { CopyableRow(title: $0.0, value: $0.1) }
                }
                Section { FirmwareUpdateRow(updater: firmware) }
                Section {
                    DisclosureRow(title: "Change Speakers…", systemImage: "arrow.left.arrow.right", action: changeSpeakers)
                } footer: {
                    Text("BookshelfBar \(Bundle.main.appVersion) · Not affiliated with KEF.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rows: [(String, String)] {
        guard let info = speaker.info else { return [("IP Address", speaker.host ?? "—")] }
        var rows = [("Name", info.name), ("Model", info.modelName), ("Primary Serial", info.serialNumber)]
        if !info.serialNumberSecondary.isEmpty { rows.append(("Secondary Serial", info.serialNumberSecondary)) }
        rows.append(("Firmware", firmware.currentVersion ?? (info.firmware.components(separatedBy: ".0x").first ?? info.firmware)))
        if let host = speaker.host { rows.append(("IP Address", host)) }
        if !info.mac.isEmpty { rows.append(("MAC Address", info.mac)) }
        return rows
    }
}


/// `LabeledContent` row whose value can be copied: a copy button appears on hover, clicking the
/// row copies, and there's a Copy item in the context menu.
struct CopyableRow: View {
    let title: String
    let value: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help("Copy \(title)")
                .opacity(hovering || copied ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: copy)
        .contextMenu { Button("Copy \(title)", action: copy) }
        .animation(.easeOut(duration: 0.15), value: hovering)
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
