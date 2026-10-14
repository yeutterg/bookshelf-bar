import KEFBarCore
import KEFKit
import SwiftUI

enum Page: String { case main, sound, about, setup }

/// The menu bar window. Each page is a grouped `Form`, the same structure System Settings and
/// the built-in menu extras use; pages swap with a native push transition.
struct RootView: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart
    @State var page: Page = .main

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if speaker.needsSetup || page == .setup {
                    SetupPage(speaker: speaker, smoothStart: smoothStart)
                } else {
                    pageView
                }
            }
            .animation(.smooth(duration: 0.3), value: page)
            .animation(.smooth(duration: 0.3), value: speaker.needsSetup)
            QuitFooter()
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
                MainPage(speaker: speaker, smoothStart: smoothStart) { page = .sound }
                    .transition(.push(from: .leading))
            case .sound:
                SoundPowerPage(speaker: speaker, back: { page = .main }, about: { page = .about })
                    .transition(.push(from: .trailing))
            case .about:
                AboutPage(speaker: speaker, back: { page = .sound }, changeSpeakers: {
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
            Text("KEF Bar \(Bundle.main.appVersion)").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit KEF Bar") { NSApp.terminate(nil) }
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
                if new > 0 { height = new }
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
