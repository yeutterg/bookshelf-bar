import KEFBarCore
import KEFKit
import SwiftUI

enum Page { case main, sound, about }

/// The popover. Pages slide horizontally like a Control Center module drill-down.
struct RootView: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart
    @State private var page: Page = .main

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            Group {
                switch page {
                case .main:
                    MainPage(speaker: speaker, smoothStart: smoothStart) { page = .sound }
                        .transition(.push(from: .leading))
                case .sound:
                    SoundPowerPage(speaker: speaker, back: { page = .main }, about: { page = .about })
                        .transition(.push(from: .trailing))
                case .about:
                    AboutPage(speaker: speaker) { page = .sound }
                        .transition(.push(from: .trailing))
                }
            }
            .animation(.smooth(duration: 0.3), value: page)
        }
        .padding(10)
        .frame(width: 340)
        .onAppear { speaker.popoverVisible = true }
        .onDisappear {
            speaker.popoverVisible = false
            page = .main
        }
    }
}

/// A rounded glass platter, the building block of every page.
struct Module<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14)
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Back chevron plus title, used by the drill-down pages.
struct PageHeader: View {
    let title: String
    var subtitle: String?
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                PaperIcon("icon-chevron-left").frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}
