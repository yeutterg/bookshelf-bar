import Foundation

/// Volume slider curve (gamma). The slider position `s` (0…1) is raised to `gamma` before it
/// reaches the native control: `native = s^gamma`. At 1.0 the slider is the native control
/// (macOS's curve on USB‑C, the speaker's own scale on other inputs). Higher values make the
/// lower and middle part of the slider quieter and move more of the change toward the top,
/// which is what feels "jumpy in the middle" on the KEF's −120…0 dB USB range.
public enum VolumeCurve {
    public static let gammaKey = "volumeGamma"
    public static let range: ClosedRange<Double> = 1.0...3.0

    public static var gamma: Double {
        let g = UserDefaults.standard.double(forKey: gammaKey)
        return g == 0 ? 1 : min(max(g, range.lowerBound), range.upperBound)
    }

    /// Slider position (0…1) → native control value (0…1).
    public static func native(fromSlider s: Double, gamma: Double) -> Double {
        pow(min(max(s, 0), 1), gamma)
    }

    /// Native control value (0…1) → slider position (0…1).
    public static func slider(fromNative n: Double, gamma: Double) -> Double {
        pow(min(max(n, 0), 1), 1 / gamma)
    }
}
