import Foundation

/// Volume slider curve (gamma). The slider position `s` (0…1) is raised to `1/gamma` before it
/// reaches the native control: `native = s^(1/gamma)`. At 1.0 the slider is the native control
/// (macOS's curve on USB‑C, the speaker's own scale on other inputs). Higher settings make the
/// lower and middle part of the slider louder and flatten the top, so the low end of the KEF's
/// −120…0 dB USB range isn't wasted on near-silence.
public enum VolumeCurve {
    public static let gammaKey = "volumeGamma"
    public static let range: ClosedRange<Double> = 1.0...3.0

    public static var gamma: Double {
        let g = UserDefaults.standard.double(forKey: gammaKey)
        return g == 0 ? 1 : min(max(g, range.lowerBound), range.upperBound)
    }

    /// Slider position (0…1) → native control value (0…1).
    public static func native(fromSlider s: Double, gamma: Double) -> Double {
        pow(min(max(s, 0), 1), 1 / gamma)
    }

    /// Native control value (0…1) → slider position (0…1).
    public static func slider(fromNative n: Double, gamma: Double) -> Double {
        pow(min(max(n, 0), 1), gamma)
    }
}
