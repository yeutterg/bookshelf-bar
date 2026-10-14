# BookshelfBar: research notes

Research, measurements and design decisions behind BookshelfBar. Device identifiers are redacted.

## 1. What we learned (live probes of your speakers on 2026-10-14 + web research)

Speaker: `LSX II LT-xxxxxx`, model SP4077, firmware `2.1.86` (`LSXIILT_V2186`),
host `lsxlite-<mac>.local`, advertised over mDNS as `_kef-info._tcp` (TXT has
model, serial, firmware, mac, kefId) and `_http._tcp`.

### Model identity, finish and artwork
- KEF exposes model and serial identity, but the live API and mDNS records do **not** expose
  a separate finish/color field.
- Decode the known finish code embedded in the serial/SKU and select the matching speaker
  artwork. Do not display the finish as text in the main UI. Persist a manual override by
  `kefId`; if the code is unknown, use a neutral rendering rather than guessing.
- The current LT serial contains `M2`, which maps to Graphite Grey. Known LT codes are
  `J2` Sage Green, `A2` Stone White and `M2` Graphite Grey. LSX II supports the broader
  finish set documented by KEF; keep the mapping data-driven so it can be extended.
- Artwork is rendered from KEF's official product GLBs through Blender, with a shared camera,
  lighting and transparent composition. The reproducible render script lives at
  `prototype-assets/render_kef_pair.py`.

### Control channel: Wi-Fi HTTP API on port 80. This is the only real option.
- **Auth:** `settings:/webserver/authMode = setData`, introduced in LT fw 2.0 (Apr 2026).
  - Reads are open.
  - Unsigned writes worked in testing for `physicalSource`, `player:volume` and `mute`.
  - Writes to `settings:/kef/host/*` and `settings:/kef/dsp/v2/*` need the
    `HMAC_SHA256_AES256` signature from the speaker-served `/jsapi/kef-api.js`.
    It's AES-256-CBC on the value, then an HMAC over `user.<salt>.<ts>.<url>.<body>`,
    with the key = sha256(salt + password). The password is "" unless set on the speaker's web page.
  - KEFKit signs every write. See Chammeister/KEF-Control `lib.rs` and EvotecIT/homeassistant-kef for working implementations.
- **Not USB.** The USB-C port is a plain USB Audio Class device. Its only control is
  a UAC volume Feature Unit (CoreAudio saved `'volm'`, output scope, elements 1 and 2).
  - That control is a **separate gain stage**. It never changes `player:volume`, and
    `player:volume` never changes it (verified both ways on your LT).
    Output ≈ speaker volume × USB attenuation.
  - On your LT, CoreAudio reports per-channel elements 1/2 (no master), a −120…0 dB range, and
    **1 dB steps** (51 distinct values across the scalar). roberdorfer measured only about 8
    audible 6 dB positions on an LSX II. Whether the LT honours every reported step is
    not yet verified acoustically.
  - The USB device has **no serial number** (VID 0x27ac, PID 0x1070), so it can't be matched to a
    network speaker by serial (see §3a).
  - No HID or vendor interface, so no input switching or settings over USB.
- **Not Bluetooth.** BLE (`settings:/bleControl`, service `1AD7C7B8-…`) is only used for
  Wi-Fi onboarding. Classic BT is an audio sink.
- The HTTP API is the same one the KEF Connect app uses. It's a StreamUnlimited-based
  "Kef_One" SDK on an i.MX8 streamer. The streamer talks to the amp/DSP MCU over "HostLink".

API shape (this firmware):
```
GET  /api/getData?path=<path>&roles=value
GET  /api/getRows?path=<container>&roles=@all&from=0&to=300     # enumerate tree
POST /api/setData   {"path":..., "roles":"value", "value":{"type":"<t>","<t>":<v>}}
                    # GET setData returns "Invalid method!" on 2.1.86
POST /api/event/modifyQueue {"subscribe":[{"path":..,"type":"itemWithValue"}],"unsubscribe":[]}
                    -> "{queue-uuid}"
GET  /api/event/pollQueue?queueId={uuid}&timeout=<s>          # long-poll, push updates
```

Paths we will use (all read live from your speaker):

| Feature | Path | Values seen |
|---|---|---|
| Input / power | `settings:/kef/play/physicalSource` | LT: `standby`, `powerOn`, `wifi`, `bluetooth`, `tv`, `optic`, `usb`; LSX II additionally reports `analog` (shown as AUX) |
| Power state | `settings:/kef/host/speakerStatus` | `standby` / `powerOn` |
| Volume | `player:volume` (i32 0–100) | per-input memory (see below) |
| Mute | `settings:/mediaPlayer/mute` | bool |
| Attenuation readout | `settings:/mediaPlayer/attenuation` | dB, e.g. 89 → −5.5, 42 → −29, 30 → −35 |
| Max volume | `settings:/kef/host/maximumVolume`, `volumeLimit` | 100, false |
| Auto standby | `settings:/kef/host/standbyMode` | `standby_30mins` (+20/60 min, never) |
| Wake source | `settings:/kef/host/wakeUpSource` | `usb` |
| Start volume after standby | `standbyDefaultVol`, `advancedStandbyDefaultVol`, `defaultVolume{Global,USB,Bluetooth,TV,Optical,Wifi}` | false, false, all 30 |
| DSP | `settings:/kef/dsp/v2/{deskMode,deskModeSetting,wallMode,wallModeSetting,bassExtension,trebleAmount,balance,phaseCorrection,highPassMode,highPassModeFreq,subwoofer*,audioPolarity,dialogueMode}` | wallMode on, bass `less`, treble −1.25 |
| EQ profile | `settings:/kef/dsp/v2/profileName` / `profileId` | "Office" |
| LEDs / panel | `settings:/kef/host/{disableFrontLED,disableFrontStandbyLED,disableTopPanel,topPanelLED,topPanelStandbyLED}` | |
| Misc | `startupTone`, `autoSwitchToHDMI`, `usbCharging`, `cableMode` (wired/wireless link), `settings:/deviceName` | |
| Now playing | `player:player/data` | streaming sources only; empty for USB |

### The volume surge: what's actually happening
Measured with the event queue while switching inputs and waking:

1. **The speaker keeps a separate stored volume for each input.** On your pair today:
   USB = **89** (−5.5 dB), Bluetooth = 30, plain `powerOn` = 42. Switching to an input
   applies its stored volume about 1.2–1.4 s after the switch.
2. **Waking takes about 2.7 s** from command to `speakerStatus=powerOn`.
   `settings:/kef/play/waitForSpeakerTimeout` = 9350 ms is the firmware's upper bound.
3. **On wake, the speaker overwrites anything written during standby.** I set
   volume 25 + mute on in standby, then woke into USB, and got volume 89 with mute *off*.
   So "pre-arm while asleep" does not work.
4. **A volume set while awake on USB *does* persist** across standby (28 stayed 28).
5. **There are two volume stages in series** (verified independent). The speaker's `player:volume`
   (0–100, stored per input) is one; the Mac's UAC hardware volume is the other. On this Mac
   the UAC was saved at −30 dB. With speaker volume 28 (−36 dB), your effective level is
   about **−66 dB in total**.
6. **Waking into USB re-enumerates the USB device** (verified, timestamped):
   - `source=usb` sent at t = 0
   - `speakerStatus=powerOn` at +2.7 s
   - CoreAudio device **removed** at +3.3 s
   - device **re-arrives** at +4.5 s with a *new AudioObjectID* (150 → 214)
   - macOS immediately re-applies its saved −30 dB
   - `player:volume` is unchanged throughout.

   In standby the USB device stays enumerated, so it only drops at wake. If the KEF is the
   default output, macOS falls back to another output during that 1.2 s gap.
7. **The speaker's volume curve is very coarse at the bottom** (`settings:/mediaPlayer/volumeMap`):

   | Volume | 1 | 3 | 5 | 7 | 10 | 15 | 20 | 28 | 40 | 50 | 71 | 89 | 100 |
   |---|---|---|---|---|---|---|---|---|---|---|---|---|---|
   | dB | −101.5 | −83.5 | −72.5 | −65 | −56.5 | −46 | −40 | −36 | −30 | −25 | −14.5 | −5.5 | 0 |

**Most likely cause** (matches community reports and roberdorfer's LSX II measurements; the
re-enumeration is now verified on your LT, but the acoustic blast is not yet measured): after
re-enumeration, the speaker's USB gain stage runs at 0 dB (no cut) until macOS's
saved volume takes effect. You briefly hear the speaker's own volume at full scale.
CoreAudio *reports* −30 dB the instant the device re-arrives, so the blast window is
inside the device or the first moments of streaming. Only an acoustic measurement settles it
(§5, test 6). One Reddit report shows the macOS volume HUD flashing 100% at that moment.

Reports of the same thing: r/KEF "LSX II LTs go to full volume for split second" (Aug 2025),
"USB-C loudness after sleep" (Nov 2024), Windows 11 spike (Jan 2026). KEF hasn't shipped a
fix for the LT; the LSX II got a related fix in fw 1.2. So the fix has to live in our app.

## 2. Fixing the surge: layered approach

The key idea is to **remove the hidden second gain stage**. If the Mac's UAC volume always
sits at 0 dB and the *real* volume lives in `player:volume`, the UAC reset on wake becomes a
no-op. The speaker wakes at its stored USB volume, which is now your actual listening
level, and that value persists across standby (verified, step 4).

| Layer | What | Cost | Expected effect |
|---|---|---|---|
| **L1 Single gain stage (core of Smooth Start)** | When the KEF USB device is present, pin its UAC volume to 1.0 (CoreAudio `kAudioDevicePropertyVolumeScalar`, elements 1/2), and re-pin on every device arrival. When the KEF is the default output, a `CGEventTap` catches the volume keys (needs Accessibility permission), and the keys plus the app slider drive `player:volume` over HTTP. Show our own volume HUD. | Medium | Removes the blast at its root. Bonus: 100 volume steps instead of about 8 coarse ones. |
| **L2 Pre-wake** | Send `usb` (wakes the speaker) *before* audio starts, using signals: KEF becomes default output, Mac wake/unlock, screen wake, Now Playing starts (MediaRemote), or a hotkey. | Small | Hides the 2.7 s wake and USB re-enumeration from you, so the first sound comes out of an awake speaker. |
| **L3 Guard** | Subscribe to `player:volume`/`speakerStatus` events. If the speaker jumps by ≥25 after a wake or reconnect (roberdorfer saw spontaneous resets), immediately write back the app's remembered target. While `IsRunningSomewhere` and the device has just re-enumerated, also briefly mute the CoreAudio device until UAC is re-pinned. | Small | Safety net for firmware quirks. |
| **L4 Native safety cap** | Set `maximumVolume` + `volumeLimit` (signed write), and optionally `standbyDefaultVol` / `defaultVolumeUSB`. | Settings change | Limits the worst case even if the app isn't running. |
| **L5 Keep-awake while you're at the Mac (opt-in)** | While the KEF is the default output and HID idle time is under N min, keep it on `usb`. Let auto-standby take over when you leave or the Mac sleeps. | Small | No cold starts during work, at roughly 10–20 W while you're active. |
| **L6 Fallback: virtual output device** | An AudioServerPlugIn "KEF Smooth" device that holds audio until the speaker is ready and forwards it with a fade-in. roberdorfer's app uses a virtual device for the same reason. | Large (HAL driver, notarization) | Guaranteed silence until ready. Only if L1–L3 leave residue. |

**⚠ Resolution problem with pure L1 (found during verification):** at your current −66 dB, a
single-stage setup puts the speaker at volume about 7, where steps are 7–9 dB apart. That's unusable
for fine control. Options, to be decided by the acoustic test:
- **L1-hybrid:** keep a *fixed* UAC pad (e.g. −24 dB) so the speaker sits at 25–45, where steps are about 0.5 dB. Smooth Start
  then mutes the CoreAudio device on re-arrival (the device exposes a mute control) and re-applies the
  pad before unmuting with a fade. This only works if the blast is a host-side race that
  mute-on-arrival can beat.
- **L1-pure + loudness reality check:** if −66 dB is just your quiet desk level, pure L1 at
  volume 5–10 is coarse but tolerable. Combine it with fine software gain inside an L6 virtual device later.
- **L6 virtual device:** if the blast happens inside the speaker before the host can act. It
  does its own fine-grained digital volume, with the hardware stages fixed.

Migration note: any mode change must keep loudness constant at the switch (total dB in = total
dB out). Onboarding does this in one step.

Gotchas from prior art:
- Below about 41, `player:volume` has hysteresis: the same number can be up to 10 dB quieter when approached from below. Always approach the target from above (roberdorfer).
- `usbCharging = true` disables USB audio, so warn if it's on.
- USB as a second wake source isn't available in ECO (20 min) standby.

Recommendation: *Smooth Start* = L1 + L2 + L3, on by default. Onboarding offers L4. L5 is a
toggle. L6 is parked.

## 3a. Setup flow (connecting over Wi-Fi)

The app doesn't put the speaker *on* Wi-Fi. That's KEF Connect's job: BLE onboarding, already
done for your pair. The app finds speakers that are already on the network and links one to
the USB device.

1. **Welcome:** explain what the app does. Trigger the **Local Network** permission prompt
   (`NSLocalNetworkUsageDescription` + `NSBonjourServices: _kef-info._tcp, _http._tcp`).
2. **Discover:** browse `_kef-info._tcp`. The TXT record already has name, model, serial,
   firmware, MAC and `kefId`, so the list can identify the exact model without any HTTP call.
   Resolve its serial finish code to the matching artwork, remember the speaker by `kefId`, and
   resolve its host each launch since the IP can change.
   - Not found? Offer: "Open KEF Connect to put your speakers on Wi-Fi", "Same network?" tips
     (guest/VLAN isolation blocks mDNS), and **manual IP entry** (validated with `getData settings:/deviceName`).
3. **Link USB:** if CoreAudio has an `AppleUSBAudioEngine:KEF:*` device:
   - one matching model on the network → link automatically.
   - several → **Identify**: briefly toggle `topPanelLED` (or play the startup tone)
     on each candidate so you can see which one is yours. There's no USB serial number to match on.
4. **Password check:** try a harmless signed write (re-write the current `topPanelLED` value).
   On 401, ask for the speaker web-page password and store it in Keychain.
5. **Smooth Start setup:** show your current effective level, pick the gain mode (from §2) and apply it
   with constant loudness. Optionally set `maximumVolume` as a safety cap.
6. **Permissions on demand:** Accessibility, requested only when you turn on "volume keys control speaker".
   Login item.

## 3. App feature scope

**MVP (menu bar popover)**
- Auto-discover speakers via `NWBrowser` on `_kef-info._tcp`. Remember by `kefId`, not IP.
- Circular Liquid Glass power control inset at the hero's top-right. It sends powered-on
  speakers to standby and wakes speakers that are already in standby; capability-driven input
  picker (Wi-Fi, Bluetooth, TV, Optical, USB-C, plus AUX when a non-LT LSX II reports the
  `analog` source)
- Volume slider + mute, live-synced via the event long-poll (reflects remote / top panel / KEF Connect changes)
- Volume keys drive `player:volume` whenever the KEF is the active output (USB under L1;
  any input when "control speaker with volume keys" is on), with a custom glass HUD
- Smooth Start toggle (L1 + L2) with a monotonic ramp glyph. During wake, show only
  **Speakers powering up** with an unlabeled progress treatment—no countdown or target-volume copy.
- Finish-correct speaker hero (standby / waking / playing / muted), selected from model + serial
- Menu bar glyph mirrors speaker state: dimmed in standby/disconnected, warm pulse while waking,
  full-colour while playing, and dimmed with a slash while muted

**v1.1: Sound & Power drill-down**
- Desk / Wall mode, bass extension, treble, balance; "Expert" disclosure for
  sub crossover, phase correction, high-pass, polarity
- Auto standby timer, wake source, start volume per input, max volume
- LED / top-panel settings, startup tone
- Keep awake while Mac is active (L3)
- About section with model, primary and secondary serial numbers, firmware and network identity.
  The main hero intentionally has no device name or metadata subtitle.

**Later:** Now Playing for Wi-Fi sources (`player:player/data`), multi-speaker picker,
Shortcuts/AppIntents ("Switch KEF to TV"), CLI (`kef vol 30`).

## 4. Architecture

- **Swift 6 + SwiftUI**, `MenuBarExtra(.window)`, macOS 27 target to get native
  Liquid Glass (`.glassEffect()`, `GlassEffectContainer`, morphing selection). Fallback
  `.ultraThinMaterial` if we decide to support macOS 15.
- **Why native Swift (lowest resource use):** the app's core is CoreAudio HAL listeners, a CGEventTap,
  Bonjour and Keychain. All are first-class in Swift and need native bridges anywhere else.
  - **Liquid Glass:** only real in SwiftUI/AppKit. Web-based UIs can only imitate it.
  - **Rough idle memory:** native SwiftUI menu bar app ≈ 15–30 MB, about 0% CPU. Tauri (Rust + WKWebView) ≈ 60–120 MB.
    react-native-macos ≈ 100 MB+. Electron 150–300 MB. Expo targets mobile, not macOS menu bar apps.
  - **Rust:** brings no benefit here. You'd still need Swift/ObjC for the UI, CoreAudio and the event tap.
  - **If the L6 virtual device is ever needed:** it's an AudioServerPlugIn written in C/C++ (real-time safe), a separate bundle.
- **Low-resource rules:**
  - No timers or polling. Use CoreAudio property listeners, `NWBrowser` and the KEF long-poll (one idle socket that wakes only on change).
  - Drop the long-poll entirely when the speaker is in standby and the popover is closed. Resume it on audio start, wake, or popover open.
  - Animations and the peak meter run only while the popover is visible: `TimelineView` paused, process tap detached otherwise.
  - LSUIElement (no Dock icon), no WebKit, no analytics.
  - Target: < 25 MB resident, < 0.1% average CPU, zero wakeups while idle.
- Modules:
  - `KEFKit`:
    - async/await HTTP client (`getData`/`setData`/`getRows`), with every write signed `HMAC_SHA256_AES256` (CryptoKit + CommonCrypto AES-CBC)
    - typed `KEFPath` enum
    - EQ via read-modify-write of `kef:eqProfile/v2` / `kef:dsp/editValue`
    - `KEFEventStream`: AsyncSequence over `pollQueue`, recreates the queue after an error or 50 s idle, and keeps the read timeout above the poll timeout
    - `KEFDiscovery`: `NWBrowser` on `_kef-info._tcp`
    - typed model capabilities and finish-code mapping; LSX II enables `analog`/AUX while
      LSX II LT does not
    - Evaluate [sbstjn/keflar](https://github.com/sbstjn/keflar) (Swift) before writing from scratch.
  - `AudioWatch`:
    - CoreAudio HAL listeners for default output device, device list (arrival/removal = re-enumeration on wake), `DeviceIsRunningSomewhere` and UAC volume
    - matches the device by UID family `AppleUSBAudioEngine:KEF:LSX II*`
    - pins UAC to 1.0
  - `VolumeKeys`: `CGEventTap` for `NX_KEYTYPE_SOUND_UP/DOWN/MUTE`, active only while the KEF is the default output; glass HUD.
  - `SmoothStart`:
    - state machine `idle → waking → settling → playing`
    - driven by AudioWatch, KEF events and NSWorkspace wake/unlock notifications
    - owns the remembered target volume and does the "approach from above" writes
  - `UI`: popover, stateful menu bar glyph, About view and finish-correct speaker assets rendered
    from the official KEF GLBs. Motion can be added later with a lightweight `TimelineView`, but
    the static official-model render remains the visual source of truth.
- No helper or daemon for MVP; LSUIElement app with a login item (`SMAppService`).
- Local network permission (`NSLocalNetworkUsageDescription`, Bonjour service key `_kef-info._tcp`).

## 5. Verification (run 2026-10-14 on this Mac; probe tools in session scratchpad `verify/`)

1. ✅ USB descriptors: VID 0x27ac / PID 0x1070, no serial. Per-channel UAC volume (el 1/2),
   −120…0 dB, 1 dB steps reported, mute control present.
2. ✅ Stages independent: UAC −54/−6/−30 dB produced no speaker events. `player:volume` 26/28 left
   UAC untouched.
3. ✅ Wake timeline: powerOn +2.7 s → USB device removed +3.3 s → re-arrives +4.5 s with
   a new ID → macOS re-applies −30 dB. `player:volume` stays put.
4. 🟡 **Acoustic surge measurement** (11 trials, Shure mic at the right speaker, 1 kHz tone, Goertzel
   meter on the same clock as the CoreAudio and KEF event logs; tools `meter`, `probe`, `trial.sh`):
   - **Wake sequence when audio starts on a sleeping KEF:**
     - +1.5–2.2 s: `physicalSource=usb` (auto-wake on USB audio)
     - +3.2–4.1 s: `powerOn`
     - +4.1–5.2 s: USB device removed
     - +4.7–8.3 s: device re-arrives
     - up to +8.7 s: macOS re-selects the KEF as default
     - about 1–2 s after re-arrival: audio resumes at the normal level
   - **2 of 11 trials had a 0.6 s burst about 45 dB above the settled level.** Both happened only when
     macOS **fell back to the Studio Display** while the KEF was gone, and the burst came *before*
     the KEF re-arrived. The Studio Display volume is −13.5 dB versus about −66 dB on the KEF path. That gap
     matches the burst, so **the burst in these tests is the fallback device, not the KEF.**
   - In u1, the KEF re-arrived with el1 at **1.000 (0 dB)** for an instant before −30 dB was applied.
     So the device does come back at full gain, but no burst was heard because audio
     resumed after the volume was restored.
   - **Two candidate mechanisms for the real-world surge:** (A) audio leaks to the fallback output during
     the 1–4 s handoff; (B) the KEF streams before macOS restores its USB gain. Both are fixed by the
     same app behaviour: pre-wake before playback (no handoff at all), or hold or mute the output
     until the KEF has re-arrived and has its gain restored.
   - **Your report:** in real use the loud part comes **from the KEFs**, with the KEF selected as output. So the
     Studio Display bursts above were a side effect of the test, not your surge.
   - **Realistic rerun** (speaker USB volume restored to 89, Studio Display muted, tone 0.2 s after
     selecting the KEF, 3 trials): the KEFs played the tone at a **constant level** (peak and median within 0.2 dB).
     You confirmed by ear that it was steady. **The surge did not reproduce from a short (10 s) standby.**
   - **Another failure mode (v1):** macOS fell back to the Studio Display during re-enumeration and
     **never switched back** to the KEF, so the audio was lost. The app should re-select the KEF as default
     output after it re-arrives, if it was the default before the drop.
   - **Hypothesis under test: deep standby.** After a long idle the speaker reports `powermanager:target =
     networkStandby` (the streamer itself is asleep). After a short standby it reports `online`.
     If the amp side wakes on USB audio before the streamer has resumed and pushed the stored volume,
     you'd get exactly a loud start that settles. `networkStandby` is reached **22 s** after standby.
     Trial `d1`, started after about 80 s in `networkStandby`, was **also steady**. Not reproduced so far.
   - **Totals:** 15 controlled trials, no KEF-side surge. What's still different from real use: (a) standby
     lasting 30+ min and entered via the auto-standby timer, (b) real apps (Music/Spotify/browser) that keep a stream
     open and resume instantly when the device re-arrives. That timing could hit the instant the device comes back at
     0 dB (caught at re-arrival in u1 and v2) before macOS restores −30 dB. afplay only resumed 1.5–3 s after re-arrival.
   - **Next:** run a passive "flight recorder" during normal use (levels only, no audio stored) and catch a real occurrence.
5. ⏳ Repeat 4 with the chosen mitigation.
6. ⏳ Signed write (e.g. `maximumVolume`) to validate the HMAC implementation. Do it during the
   KEFKit spike.

## 6. Milestones
1. `KEFKit` + CLI spike: discovery, get/set, event stream; run the §5 tests (½ day)
2. Menu bar MVP: power, inputs, volume/mute, live sync (1–2 days)
3. Smooth Start L1–L3 + volume-key tap + onboarding migration (2 days, mostly tuning against real timings)
4. Speaker hero animations + Liquid Glass polish (1–2 days)
5. Sound & Power drill-down (signed writes), L4/L5 toggles (1 day)
6. Setup flow (§3a), login item, signing/notarization, Sparkle (optional)

## 7. Prior art (read before building)
- Menu bar apps:
  - roberdorfer/kef-lsx-volume: the closest match to our USB approach, using a virtual device and network volume
  - tkelkermans/KefSleepSync: signed writes, volume keys, follows Mac sleep
  - amebalabs/Kefir, nickvanw/KEFControl
- Libraries and tools:
  - sbstjn/keflar (Swift)
  - Chammeister/KEF-Control (Rust signing)
  - EvotecIT/homeassistant-kef (best API notes, tested on an LT)
  - hilli/go-kef-w2 (port 4430 auth)
  - N0ciple/pykefcontrol
- Clones are in the session scratchpad: `…/scratchpad/src/`.

## 8. Standby findings (2026-10-14, later)

- **Held audio streams re-wake the speaker.** With Wake On = USB Audio, if any app holds an
  audio stream open to the KEF when it enters standby (seen: iOS Simulator, via
  `pmset -g assertions` → `audio-out AppleUSBAudioEngine:KEF:…`), the speaker wakes itself again
  about 3 s later. This happens with the speaker's own power button too, so it's firmware behaviour.
- **Wake On is only checked at standby entry.** Setting `wakeUpSource = wakeup_default`, entering
  standby, then restoring `usb` keeps the speaker asleep even with the stream still held.
- **Side effect:** entering standby with USB wake off powers down the speaker's USB interface
  (the CoreAudio device disappears) until the next wake, so Mac audio can't wake it. BookshelfBar
  therefore uses this only when a stream is held, where plain standby wouldn't stick at all.
- With Wake On = USB Audio and no held stream, the USB device stays present through light and
  deep (`networkStandby`) standby, so playing audio wakes the speaker as before.
