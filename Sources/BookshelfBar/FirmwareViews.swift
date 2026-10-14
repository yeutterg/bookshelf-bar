import BookshelfBarCore
import SwiftUI

/// Firmware row in Settings › About: check, see what's available, install with a warning.
struct FirmwareUpdateRow: View {
    let updater: FirmwareUpdater
    @State private var confirming: String?

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Firmware Update")
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
            Spacer()
            action
        }
        .task { await updater.refresh() }
        .confirmationDialog("Install firmware \(confirming ?? "")?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Install Update") {
                confirming = nil
                Task { await updater.install() }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(FirmwareText.warning)
        }
    }

    private var detail: String? {
        switch updater.phase {
        case .unknown: updater.currentVersion.map { "Installed: \($0)" }
        case .checking: "Checking with KEF…"
        case .upToDate: "Up to date\(updater.currentVersion.map { " (\($0))" } ?? "")"
        case .available(let v): "Version \(v) is available"
        case .downloading(let p): "Downloading… \(p)%"
        case .installing: "Installing…"
        case .finished(let v): "Updated to \(v)"
        case .failed(let message): message
        }
    }

    @ViewBuilder private var action: some View {
        switch updater.phase {
        case .available(let v):
            Button("Install…") { confirming = v }.buttonStyle(.borderedProminent)
        case .checking:
            ProgressView().controlSize(.small)
        default:
            Button("Check") { Task { await updater.check() } }
        }
    }
}

enum FirmwareText {
    static let warning = """
    Your speakers will restart during the update, which can take up to 20 minutes.

    Don't switch off or unplug the speakers, disconnect the cable between them, or take them off Wi‑Fi until the update finishes. Interrupting an update can leave the speakers unusable.

    BookshelfBar pauses all controls and automations, including Smooth Start and Keep Awake, until the speakers report the update is complete.
    """
}

/// Replaces the whole popover while an update is running: nothing here can send a command.
struct FirmwareLockPage: View {
    let updater: FirmwareUpdater

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
            Text("Updating Speaker Firmware").font(.headline)
            progress
            Text("Don't switch off or unplug the speakers, or take them off Wi‑Fi. They'll restart during the update. BookshelfBar is paused until they report the update is complete.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if case .failed(let message) = updater.phase {
                Text(message).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            if updater.canForceUnlock {
                Button("Unlock BookshelfBar") { updater.forceUnlock() }
                    .help("Only if KEF Connect shows the update has finished")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var progress: some View {
        switch updater.phase {
        case .downloading(let p):
            ProgressView(value: Double(p), total: 100) { Text("Downloading \(p)%").font(.caption) }
        case .installing(let p):
            ProgressView(value: Double(p), total: 100) { Text(p > 0 ? "Installing \(p)%" : "Installing…").font(.caption) }
        default:
            ProgressView().controlSize(.small)
        }
    }
}
