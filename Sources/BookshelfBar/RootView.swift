import BookshelfBarCore
import KEFKit
import SwiftUI

enum Page: String { case main, settings, about, setup }

/// The menu bar window. Each page keeps the native grouped-form structure and push transition.
struct RootView: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart
    let keepAwake: KeepAwake
    let firmware: FirmwareUpdater
    @State var page: Page = .main

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if speaker.isUpdatingFirmware {
                    FirmwareLockPage(updater: firmware)
                } else if speaker.needsSetup || page == .setup {
                    SetupPage(speaker: speaker, smoothStart: smoothStart)
                } else {
                    pageView
                }
            }
            .animation(.smooth(duration: 0.3), value: page)
            .animation(.smooth(duration: 0.3), value: speaker.needsSetup)
            // On the main page Quit is a row under Settings; elsewhere it's a small footer.
            if page != .main || speaker.needsSetup || speaker.isUpdatingFirmware { QuitFooter() }
        }
        .frame(width: 320)
        .onAppear { speaker.popoverVisible = true }
        .onDisappear {
            speaker.popoverVisible = false
            page = .main
        }
    }

    @ViewBuilder private var pageView: some View {
        switch page {
            case .main:
                MainPage(speaker: speaker, smoothStart: smoothStart, keepAwake: keepAwake,
                         openSettings: { page = .settings }, openAbout: { page = .about })
                    .transition(.push(from: .leading))
            case .settings:
                SettingsPage(speaker: speaker, back: { page = .main })
                    .transition(.push(from: .trailing))
            case .about:
                AboutPage(speaker: speaker, firmware: firmware, back: { page = .main }, changeSpeakers: {
                    page = .main
                    speaker.forget()
                })
                    .transition(.push(from: .trailing))
            case .setup:
                EmptyView()
        }
    }
}

/// Bottom bar on every page, like the last item of a menu extra.
struct QuitFooter: View {
    var body: some View {
        HStack {
            Spacer()
            Button("Quit BookshelfBar") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .padding(.top, 2)
    }
}

/// A grouped form that sizes itself to its content, so the menu bar window fits each page.
struct PageForm<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 200

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, new in
                guard new > 0, abs(new - height) > 0.5 else { return }
                // Apply size changes instantly; animating the window height while rows also
                // animate is what made the standby ↔ on transition jitter.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { height = new }
            }
            .frame(height: height)
    }
}

/// Back button and title for drill-down pages.
struct PageHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack {
            Button(action: back) {
                Label("Back", systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .controlSize(.large)
            .help("Back")
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }
}

/// A form row that behaves like a navigation link.
struct DisclosureRow: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
                Spacer()
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary).imageScale(.small)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
