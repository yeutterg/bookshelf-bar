import Foundation

/// A node in the speaker's settings tree, e.g. `settings:/kef/play/physicalSource`.
public struct KEFPath: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

public extension KEFPath {
    // Power and input
    static let physicalSource: KEFPath = "settings:/kef/play/physicalSource"
    static let speakerStatus: KEFPath = "settings:/kef/host/speakerStatus"
    static let powerTarget: KEFPath = "powermanager:target"

    // Volume
    static let volume: KEFPath = "player:volume"
    static let mute: KEFPath = "settings:/mediaPlayer/mute"
    static let attenuation: KEFPath = "settings:/mediaPlayer/attenuation"
    static let maximumVolume: KEFPath = "settings:/kef/host/maximumVolume"
    static let volumeLimit: KEFPath = "settings:/kef/host/volumeLimit"
    static let volumeStep: KEFPath = "settings:/kef/host/volumeStep"
    static let standbyDefaultVolume: KEFPath = "settings:/kef/host/standbyDefaultVol"
    static let advancedStandbyDefaultVolume: KEFPath = "settings:/kef/host/advancedStandbyDefaultVol"
    static func defaultVolume(_ source: PhysicalSource?) -> KEFPath {
        let suffix = switch source {
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .tv: "TV"
        case .optical: "Optical"
        case .wifi: "Wifi"
        default: "Global"
        }
        return KEFPath("settings:/kef/host/defaultVolume\(suffix)")
    }

    // Power behaviour
    static let standbyMode: KEFPath = "settings:/kef/host/standbyMode"
    static let wakeUpSource: KEFPath = "settings:/kef/host/wakeUpSource"
    static let autoSwitchToHDMI: KEFPath = "settings:/kef/host/autoSwitchToHDMI"
    static let startupTone: KEFPath = "settings:/kef/host/startupTone"
    static let usbCharging: KEFPath = "settings:/kef/host/usbCharging"

    // DSP (writes require a signed request on fw 2.0+)
    static let deskMode: KEFPath = "settings:/kef/dsp/v2/deskMode"
    static let deskModeSetting: KEFPath = "settings:/kef/dsp/v2/deskModeSetting"
    static let wallMode: KEFPath = "settings:/kef/dsp/v2/wallMode"
    static let wallModeSetting: KEFPath = "settings:/kef/dsp/v2/wallModeSetting"
    static let bassExtension: KEFPath = "settings:/kef/dsp/v2/bassExtension"
    static let trebleAmount: KEFPath = "settings:/kef/dsp/v2/trebleAmount"
    static let balance: KEFPath = "settings:/kef/dsp/v2/balance"
    static let phaseCorrection: KEFPath = "settings:/kef/dsp/v2/phaseCorrection"
    static let profileName: KEFPath = "settings:/kef/dsp/v2/profileName"

    // LEDs
    static let topPanelLED: KEFPath = "settings:/kef/host/topPanelLED"
    static let topPanelStandbyLED: KEFPath = "settings:/kef/host/topPanelStandbyLED"
    static let disableTopPanel: KEFPath = "settings:/kef/host/disableTopPanel"

    // Identity
    static let deviceName: KEFPath = "settings:/deviceName"
    static let modelName: KEFPath = "settings:/kef/host/modelName"
    static let releaseText: KEFPath = "settings:/releasetext"
    static let firmwareVersion: KEFPath = "settings:/version"
    static let authMode: KEFPath = "settings:/webserver/authMode"

    // Playback
    static let playerData: KEFPath = "player:player/data"
    static let playerControl: KEFPath = "player:player/control"
}

/// Inputs. The firmware accepts every name on every model; the LSX II LT has no analog or coaxial.
public enum PhysicalSource: String, Sendable, CaseIterable, Codable {
    case wifi, bluetooth, tv, optical, usb
    case analog, coaxial
    case standby, powerOn

    public static let kefType = "kefPhysicalSource"
    public static let lsxIILT: [PhysicalSource] = [.wifi, .bluetooth, .tv, .optical, .usb]
    public static let lsxII: [PhysicalSource] = [.wifi, .bluetooth, .tv, .optical, .usb, .analog]

    /// Inputs that physically exist on a model (by Bonjour `modelName`).
    public static func inputs(forModel modelName: String) -> [PhysicalSource] {
        switch modelName {
        case "LSX II LT": lsxIILT
        case "LSX II", "LS50 Wireless II", "LS60 Wireless": lsxII
        default: lsxIILT
        }
    }
    public var value: KEFValue { .enumeration(Self.kefType, rawValue) }
}

public enum SpeakerStatus: String, Sendable, Codable {
    case standby, powerOn
}

public enum StandbyMode: String, Sendable, CaseIterable, Codable {
    case eco = "standby_20mins"
    case thirtyMinutes = "standby_30mins"
    case sixtyMinutes = "standby_60mins"
    case never = "standby_none"

    public static let kefType = "kefStandbyMode"
    public var value: KEFValue { .enumeration(Self.kefType, rawValue) }
}

public enum WakeUpSource: String, Sendable, CaseIterable, Codable {
    case none = "wakeup_default"
    case tv, optical, bluetooth, usb, wifi

    public static let kefType = "kefWakeUpSource"
    public var value: KEFValue { .enumeration(Self.kefType, rawValue) }
}

public enum BassExtension: String, Sendable, CaseIterable, Codable {
    case less, standard, extra
    public var value: KEFValue { .string(rawValue) }
}
