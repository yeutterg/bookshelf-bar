import KEFBarCore
import SwiftUI

/// SF Symbol speaker pair: outline in standby, filled when on, pulsing while Smooth Start wakes
/// the speakers, and a slashed speaker when muted.
struct MenuBarIcon: View {
    let speaker: SpeakerModel
    let smoothStart: SmoothStart

    var body: some View {
        let state = speaker.visualState(smoothStart)
        Image(systemName: symbol(state))
            .symbolEffect(.pulse, isActive: state == .waking)
            .accessibilityLabel("KEF Bar")
    }

    private func symbol(_ state: SpeakerState) -> String {
        switch state {
        case .offline, .standby: "hifispeaker.2"
        case .waking, .playing: "hifispeaker.2.fill"
        case .muted: "speaker.slash.fill"
        }
    }
}
