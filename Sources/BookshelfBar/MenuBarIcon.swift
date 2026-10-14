import BookshelfBarCore
import SwiftUI

/// The compact two-cabinet glyph from the Paper prototype. Motion exists only while a transient
/// or active playback state is on screen; idle, standby and muted states schedule no work.
struct MenuBarIcon: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = speaker.visualState(smoothStart)
        ZStack {
            HStack(spacing: 2) {
                MenuBarCabinet(leansLeft: false, emphasized: emphasized(state))
                MenuBarCabinet(leansLeft: true, emphasized: emphasized(state))
            }

            if state == .playing || state == .waking || state == .reconnecting {
                MenuBarActivity(state: state, reduceMotion: reduceMotion)
            }

            if state == .muted {
                Capsule()
                    .fill(.primary)
                    .frame(width: 1.5, height: 21)
                    .rotationEffect(.degrees(45))
            }
        }
        .frame(width: 21, height: 16)
        .opacity(opacity(state))
        .accessibilityElement(children: .ignore)
            .accessibilityLabel(label(state))
    }

    private func emphasized(_ state: SpeakerState) -> Bool {
        switch state {
        case .on, .playing, .waking: true
        case .offline, .reconnecting, .standby, .muted: false
        }
    }

    private func opacity(_ state: SpeakerState) -> Double {
        switch state {
        case .offline: 0.38
        case .standby: 0.58
        case .reconnecting: 0.7
        case .waking, .on, .playing, .muted: 1
        }
    }

    private func label(_ state: SpeakerState) -> String {
        switch state {
        case .offline: "KEF speakers offline"
        case .reconnecting: "KEF speakers reconnecting"
        case .standby: "KEF speakers in standby"
        case .waking: "KEF speakers powering up"
        case .on: "KEF speakers on"
        case .playing: "KEF speakers playing"
        case .muted: "KEF speakers muted"
        }
    }
}

private struct MenuBarCabinet: View {
    let leansLeft: Bool
    let emphasized: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.25, style: .continuous)
                .fill(.primary.opacity(emphasized ? 0.16 : 0.04))
            RoundedRectangle(cornerRadius: 2.25, style: .continuous)
                .stroke(.primary, lineWidth: emphasized ? 1.15 : 0.95)
            Circle()
                .stroke(.primary, lineWidth: 0.9)
                .frame(width: 4.7, height: 4.7)
                .offset(y: -1.2)
            Circle()
                .fill(.primary)
                .frame(width: emphasized ? 1.8 : 1.35, height: emphasized ? 1.8 : 1.35)
                .offset(y: -1.2)
            Circle()
                .fill(.primary.opacity(0.8))
                .frame(width: 0.9, height: 0.9)
                .offset(y: 4.6)
        }
        .frame(width: 7.5, height: 14)
        .rotationEffect(.degrees(leansLeft ? -2.5 : 2.5), anchor: .bottom)
    }
}

private struct MenuBarActivity: View {
    let state: SpeakerState
    let reduceMotion: Bool
    @State private var expanded = false

    var body: some View {
        ZStack {
            activityRing(x: -4.75, delay: 0)
            activityRing(x: 4.75, delay: state == .playing ? 0.32 : 0)
        }
        .onAppear { expanded = true }
    }

    private func activityRing(x: CGFloat, delay: Double) -> some View {
        Circle()
            .stroke(.primary.opacity(reduceMotion ? 0.32 : (expanded ? 0 : 0.48)), lineWidth: 0.85)
            .frame(width: 5.2, height: 5.2)
            .scaleEffect(reduceMotion ? 1.25 : (expanded ? 1.65 : 0.82))
            .offset(x: x, y: -1.2)
            .animation(
                reduceMotion ? nil : .easeOut(duration: state == .playing ? 1.35 : 0.9)
                    .delay(delay)
                    .repeatForever(autoreverses: false),
                value: expanded
            )
    }
}
