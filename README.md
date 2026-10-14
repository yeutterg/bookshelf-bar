# BookshelfBar

A native macOS menu bar app for KEF wireless speakers (LSX II LT, LSX II and the rest of the W2 platform), with a fix for the volume surge when a sleeping speaker starts playing over USB.

- **Control:** power, input, volume and mute, plus desk/wall mode, bass extension, treble, balance, auto-standby, wake source and maximum volume.
- **Smooth Start:** wakes the speakers before audio plays, guards the moment the speaker reconnects over USB, and fades back in. It also puts macOS output back on the KEF if macOS switched away while the speaker was reconnecting.
- **Keep Awake With Screen:** optional. The speakers stay on while the Mac's screen is on and go to standby when it turns off, if nothing is playing.
- **Off stays off:** turning the speakers off works even when an app (a browser tab, the iOS Simulator) holds an audio stream open, which otherwise wakes KEF speakers straight back up.
- **Live:** reflects changes made with the remote, top panel or KEF Connect.
- **Setup:** on first launch you choose which pair this Mac controls (**Identify** wakes a pair briefly so you can tell which one it is). The choice is remembered by the speaker's permanent KEF ID, and **Change Speakers…** in About switches pairs.
- **Native and light:** SwiftUI with system controls and SF Symbols, no polling, and no network connection at all while the speakers are in standby and the popover is closed.

Requires macOS 26 or later. Not affiliated with KEF.

## Install

```sh
brew install --cask yeutterg/tap/bookshelfbar
```

Or download the DMG from [Releases](https://github.com/yeutterg/bookshelf-bar/releases), open it, and drag BookshelfBar to Applications. Releases are signed with a Developer ID and notarized by Apple.

On first launch macOS asks for Local Network access, which BookshelfBar needs to find and control your speakers.

## Build

```sh
swift build                 # library, CLI and app
swift test                  # unit tests
scripts/bundle.sh           # builds build/BookshelfBar.app
open build/BookshelfBar.app
```

On first launch macOS asks for Local Network access, which the app needs to find and control the speakers.

## kefctl

A command-line tool on top of the same library, handy for scripting and debugging:

```sh
swift run kefctl discover
swift run kefctl info
swift run kefctl vol 30
swift run kefctl source usb
swift run kefctl events          # live changes
swift run kefctl usb             # KEF USB audio device state on this Mac
```

## How it works

The speakers expose a local HTTP API on port 80, the same one KEF Connect uses. Since firmware 2.0, writes to settings (DSP, power options) must be signed with the speaker's `HMAC_SHA256_AES256` scheme; `KEFKit` implements it. The USB port is a plain USB Audio Class device, so all control goes over the network.

When a sleeping speaker starts playing over USB, it wakes, drops off the USB bus about 3 s later, and comes back 1–4 s after that as a new audio device. Sometimes it returns at full USB gain before macOS restores the saved volume, and sometimes macOS moves output to another device and doesn't move it back. [docs/RESEARCH.md](docs/RESEARCH.md) has the measurements, the API notes and the design decisions.

## Layout

| Target | What |
|---|---|
| `KEFKit` | HTTP client, request signing, event stream, Bonjour discovery, finish decoding |
| `KEFAudio` | CoreAudio: the KEF USB device, its volume, mute and default-output state |
| `BookshelfBarCore` | Speaker model for the UI and the Smooth Start logic |
| `BookshelfBar` | The SwiftUI menu bar app |
| `kefctl` | CLI |

## Credits

Request signing is adapted from [tkelkermans/KefSleepSync](https://github.com/tkelkermans/KefSleepSync) (0BSD). The API notes draw on [EvotecIT/homeassistant-kef](https://github.com/EvotecIT/homeassistant-kef), [N0ciple/pykefcontrol](https://github.com/N0ciple/pykefcontrol), [hilli/go-kef-w2](https://github.com/hilli/go-kef-w2) and [roberdorfer/kef-lsx-volume](https://github.com/roberdorfer/kef-lsx-volume). KEF, LSX and Uni-Q are trademarks of GP Acoustics. Speaker artwork is rendered from KEF's product models.

## License

MIT

## Releasing

Push a tag like `v0.2.0`. The [release workflow](.github/workflows/release.yml) tests, builds a universal app, signs it, notarizes and staples the DMG, publishes a GitHub release, and updates the cask in [yeutterg/homebrew-tap](https://github.com/yeutterg/homebrew-tap). Repository secrets:

| Secret | What |
|---|---|
| `DEVELOPER_ID_P12` | Developer ID Application certificate + private key, exported as .p12, base64-encoded |
| `DEVELOPER_ID_P12_PASSWORD` | Password for that .p12 |
| `NOTARY_KEY_P8` | App Store Connect API key (.p8 contents) for `notarytool` |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | That key's ID and issuer ID |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token with write access to `yeutterg/homebrew-tap` |

Without the signing secrets the workflow still builds a DMG, but it isn't notarized. Locally: `VERSION=0.2.0 scripts/release.sh` (set `SIGN_IDENTITY` and the `NOTARY_*` variables to sign and notarize).

