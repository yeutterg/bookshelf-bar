import AppKit
import Foundation
import KEFAudio
import KEFKit

// kefctl: command-line access to KEFKit, for development and scripting.
//
//   kefctl discover                 list speakers on the network
//   kefctl info                     name, model, firmware, power, input, volume
//   kefctl vol [0-100]              get or set volume
//   kefctl mute [on|off]            get or set mute
//   kefctl source [wifi|bluetooth|tv|optical|usb|standby]
//   kefctl get <path>               raw read, e.g. settings:/kef/host/standbyMode
//   kefctl rows <path>              list a settings container
//   kefctl set <path> <type> <val>  raw write, e.g. set settings:/kef/host/maximumVolume i32_ 100
//   kefctl events                   stream live changes
//   kefctl usb                      KEF USB audio device state on this Mac
//   kefctl firmware [check]         firmware update status (and ask the speaker to check)
//   kefctl sign-test                re-write maximumVolume with its current value via a signed request
//
// Target speaker: --host <ip|name>, or $KEF_HOST, or the first one found via Bonjour.
// $KEF_PASSWORD: speaker web-page password (default none). $KEF_SIGNING: automatic|always|never.

let (args, hostArg): ([String], String?) = {
    var a = Array(CommandLine.arguments.dropFirst())
    guard let i = a.firstIndex(of: "--host"), i + 1 < a.count else { return (a, nil) }
    let h = a[i + 1]
    a.removeSubrange(i...(i + 1))
    return (a, h)
}()
let command = args.first ?? "info"
let rest = Array(args.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kefctl: \(message)\n".utf8))
    exit(1)
}

func firstSpeaker(timeout: Duration = .seconds(4)) async -> KEFSpeakerInfo? {
    await withTaskGroup(of: KEFSpeakerInfo?.self) { group in
        group.addTask {
            for await list in KEFDiscovery().speakers() where !list.isEmpty { return list[0] }
            return nil
        }
        group.addTask { try? await Task.sleep(for: timeout); return nil }
        let found = await group.next() ?? nil
        group.cancelAll()
        return found
    }
}

let env = ProcessInfo.processInfo.environment
let password = env["KEF_PASSWORD"] ?? ""
let signing: KEFClient.Signing = switch env["KEF_SIGNING"] {
case "always": .always
case "never": .never
default: .automatic
}

func client() async -> KEFClient {
    if let h = hostArg ?? env["KEF_HOST"] { return KEFClient(host: h, password: password, signing: signing) }
    guard let speaker = await firstSpeaker() else { fail("no speaker found; pass --host") }
    do { return KEFClient(host: try await KEFDiscovery.resolveHost(for: speaker), password: password, signing: signing) }
    catch { fail("could not resolve \(speaker.name): \(error.localizedDescription)") }
}

func show(_ v: KEFValue) -> String {
    switch v.payload {
    case .string(let s): s
    case .int(let i): "\(i)"
    case .double(let d): "\(d)"
    case .bool(let b): "\(b)"
    default: String(decoding: (try? JSONEncoder().encode(v.payload)) ?? Data(), as: UTF8.self)
    }
}

func parseValue(type: String, _ raw: String) -> KEFValue {
    switch type {
    case "bool_": .bool(raw == "true" || raw == "1" || raw == "on")
    case "i16_": .i16(Int(raw) ?? 0)
    case "i32_": .i32(Int(raw) ?? 0)
    case "double_": .double(Double(raw) ?? 0)
    case "string_": .string(raw)
    default: .enumeration(type, raw)
    }
}

do {
    switch command {
    case "discover":
        guard let s = await firstSpeaker(timeout: .seconds(4)) else { print("no speakers found"); break }
        let host = (try? await KEFDiscovery.resolveHost(for: s)) ?? "?"
        print("\(s.name)\t\(s.modelName)\tfw \(s.firmware)\t\(host)\tkefId \(s.kefId)")

    case "info":
        let c = await client()
        async let name = c.deviceName()
        async let model = c.get(.releaseText)
        async let status = c.status()
        async let source = c.source()
        async let volume = c.volume()
        async let muted = c.isMuted()
        async let power = c.powerTarget()
        print("""
        name:    \(try await name)
        release: \(show(try await model))
        host:    \(c.host)
        status:  \(try await status.rawValue) (\(try await power))
        input:   \(try await source.rawValue)
        volume:  \(try await volume)\(try await muted ? " (muted)" : "")
        """)

    case "vol":
        let c = await client()
        if let v = rest.first.flatMap(Int.init) { try await c.setVolume(v) }
        print(try await c.volume())

    case "mute":
        let c = await client()
        if let v = rest.first { try await c.setMuted(v == "on" || v == "true") }
        print(try await c.isMuted() ? "on" : "off")

    case "source":
        let c = await client()
        if let s = rest.first {
            guard let src = PhysicalSource(rawValue: s) else { fail("unknown source \(s)") }
            try await c.setSource(src)
        }
        print(try await c.source().rawValue)

    case "get":
        guard let p = rest.first else { fail("usage: get <path>") }
        print(show(try await client().get(KEFPath(p))))

    case "rows":
        guard let p = rest.first else { fail("usage: rows <path>") }
        for row in try await client().rows(KEFPath(p)) {
            print("\(row.path?.rawValue ?? "?")\t\(row.value.map(show) ?? "")")
        }

    case "set":
        guard rest.count == 3 else { fail("usage: set <path> <type> <value>") }
        let c = await client()
        try await c.set(KEFPath(rest[0]), parseValue(type: rest[1], rest[2]))
        print(show(try await c.get(KEFPath(rest[0]))))

    case "events":
        let c = await client()
        let paths: [KEFPath] = rest.isEmpty
            ? [.physicalSource, .speakerStatus, .volume, .mute, .powerTarget]
            : rest.map { KEFPath($0) }
        for await e in c.events(paths) {
            print("\(Date().formatted(.dateTime.hour().minute().second()))  \(e.path)  \(e.value.map(show) ?? "-")")
        }

    case "usb":
        guard let id = KEFUSBMonitor.findKEF() else { print("no KEF USB audio device"); break }
        let db = AudioHardware.volumeDecibels(id).map { String(format: "%.1f dB", $0) } ?? "-"
        print("""
        device:  \(AudioHardware.name(id) ?? "?") (id \(id))
        uid:     \(AudioHardware.uid(id) ?? "?")
        default: \(AudioHardware.defaultOutput() == id)
        running: \(AudioHardware.isRunningSomewhere(id))
        volume:  \(AudioHardware.volume(id).map { String(format: "%.3f", $0) } ?? "-") (\(db))
        muted:   \(AudioHardware.isMuted(id).map(String.init) ?? "-")
        playing: \(AudioHardware.processesPlaying(to: id).map { pid in
            NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)" }.joined(separator: ", "))
        """)

    case "firmware":
        let c = await client()
        if rest.first == "check" { try await c.checkForFirmwareUpdate(); try await Task.sleep(for: .seconds(4)) }
        print(String(decoding: try JSONEncoder().encode(try await c.get("firmwareupdate:updateStatus").payload), as: UTF8.self))

    case "sign-test":
        let c = KEFClient(host: (await client()).host, password: password, signing: .always)
        let current = try await c.get(.maximumVolume)
        try await c.set(.maximumVolume, current)
        print("signed write accepted (maximumVolume = \(show(try await c.get(.maximumVolume))))")

    default:
        fail("unknown command \(command)")
    }
} catch {
    fail(error.localizedDescription)
}
