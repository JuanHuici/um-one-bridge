# UM-ONE Bridge

A user-space driver for the **original** Roland UM-ONE USB MIDI interface (USB 0582:012A) on macOS 15 and later,
on both Apple Silicon and Intel Macs.

Roland's last driver for the original UM-ONE targets macOS 10.12, and current macOS leaves the device
unconfigured, so it never shows up as a MIDI port. UM-ONE Bridge is a small menu bar app that talks to the
interface directly and publishes it to CoreMIDI. It has no dependencies: just IOUSBHost and CoreMIDI
(UMP, MIDI 1.0 protocol). No kernel extension, no DriverKit, no libusb.

The **UM-ONE mk2** does not need this: Roland still provides a current driver for it.

## Features

- Several UM-ONEs at once, each exposed as a MIDI source and destination named "UM-ONE 1", "UM-ONE 2"…
- Stable names and MIDI IDs per USB port, so your DAW keeps its routing across launches and replugs.
- Hot-plug: unplug and replug at any time; the ports go offline and come back on their own.
- Full MIDI 1.0: notes and controllers, SysEx of any length, System Common and Real-Time messages.
- Menu with each device's status and message counters, a launch-at-login option and a verbose mode that logs raw USB packets.

## Installation

1. Download the `.dmg` from the latest release under Releases.
2. Drag **UM-ONE Bridge** to Applications and open it. A keyboard icon appears in the menu bar; there is no Dock icon or window.
3. Plug in your UM-ONE(s). They appear as "UM-ONE 1", "UM-ONE 2"… in Audio MIDI Setup and in your DAW.

The app is signed with a Developer ID and notarized by Apple.

## Project layout

- `UMONEBridge.xcodeproj`: the "UM-ONE Bridge" app (LSUIElement, not sandboxed).
- `UMONEBridge/`: UI (MenuBarExtra), model, login item (SMAppService).
- `Packages/UMOneCore/`: everything else, no UI.
  - `USBMIDICodec.swift`: USB-MIDI ↔ UMP (Code Index Number tables, SysEx, System Common, Real-Time).
  - `UMOneConnection.swift`: interface 0, continuous asynchronous bulk reads on 0x81, write queue on 0x02.
  - `DeviceManager.swift`: IOKit arrival/removal notifications, SET_CONFIGURATION 1 with retries.
  - `MIDIPort.swift`: virtual source + destination "UM-ONE n", stable IDs, offline while unplugged.
  - `BridgeService.swift`: ties everything together; slot per locationID persisted in UserDefaults.
  - `umone-diag`: diagnostic tool.

## Building

The Release configuration signs with the author's Developer ID. To build without that certificate,
sign locally:

```bash
xcodebuild -project UMONEBridge.xcodeproj -scheme UMONEBridge -configuration Release -derivedDataPath build/DerivedData \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM= build
cp -R "build/DerivedData/Build/Products/Release/UM-ONE Bridge.app" /Applications/
```

Launch at login works best with the app in /Applications.

## Making a release

`scripts/release.sh` builds a universal binary, checks the Developer ID signature and Hardened Runtime,
creates `dist/UM-ONE-Bridge-<version>.dmg`, signs it, notarizes it and staples the ticket. Once beforehand:

```bash
xcrun notarytool store-credentials umone-notary --apple-id <apple-id> --team-id U3T5TG2HFV
```

The first time, macOS asks to let `codesign` use the key in your keychain: choose "Always Allow".
`scripts/release.sh --skip-notarize` produces a signed but not notarized DMG, for testing.

## Diagnostics

```bash
cd Packages/UMOneCore && swift build && swift test
.build/debug/umone-diag --descriptors        # open, print descriptors, configure, open pipes, close
.build/debug/umone-diag --dump               # raw USB-MIDI packets (quit the app first)
.build/debug/umone-diag --send-note          # middle C on channel 1 through each UM-ONE
.build/debug/umone-diag --reset --location 0x10321000   # re-enumerate: same as unplug + replug
.build/debug/umone-diag --headless --verbose # the full bridge without the UI
```

Verbose mode (from the menu or `--verbose`) sends raw packets to os_log, category `raw`:

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "com.juanhuici.umone-bridge"'
```

## Notes

- Names follow the **USB port** (`locationID`), not the unit: the UM-ONE has no serial number.
  If you swap two UM-ONEs between ports, their names swap too.
- `--dump`, `--send-note` and `--headless` need exclusive access to the interface: quit the app first.

## Acknowledgements

[giulioz/um-one-macos](https://github.com/giulioz/um-one-macos) showed that the original UM-ONE works
on modern macOS from user space and documented the endpoints it uses (interface 0, bulk 0x02/0x81).
UM-ONE Bridge is an independent implementation and contains no code from that project.

## License

MIT, see [LICENSE](LICENSE).

Roland and UM-ONE are trademarks of Roland Corporation. This project is independent and is not
affiliated with, endorsed by or supported by Roland. It is provided as is, without warranty.
