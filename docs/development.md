# Development

## Build

Install Apple's command-line developer tools and use a Swift 6 toolchain on macOS 14.4 or later.

```sh
./scripts/build.sh
```

The script builds the release executable using Swift Package Manager, creates `dist/Volume Mixer.app`, copies its Info.plist, and ad-hoc signs the bundle. There are no third-party package dependencies. Build output is excluded from Git.

For compiler checks during development:

```sh
swift build
```

For local installation, quit the running app before replacing the Applications copy. macOS may ask for audio capture permission again after a rebuild.

## Source layout

| Path | Purpose |
| --- | --- |
| `Sources/VolumeMixer/VolumeMixer.swift` | SwiftUI menu-bar interface, running-app model, route lifecycle, and login item preference. |
| `Sources/AudioBridge/AudioBridge.m` | Audio process discovery, helper ownership, process taps, private aggregate devices, and real-time DSP. |
| `Sources/AudioBridge/include/AudioBridge.h` | Objective-C/C API imported by Swift. |
| `Resources/Info.plist` | Bundle identity, minimum OS, menu-bar-only mode, and audio permission explanation. |
| `Tests/AudioTests.m` | Offline assertions for the DSP kernel. |
| `scripts/build.sh` | Release build and app packaging. |
| `scripts/test.sh` | Synthetic audio-buffer harness plus a Swift build. |

## Audio flow

```text
100%: application → normal macOS output

Below 100%:
application → private process tap → bounded gain → private aggregate → default output
               original stream muted while tapped
```

The mixer does not set the system's default output device or its volume. Each attenuated application gets one route containing its associated audio process objects. Returning to 100% stops the IO callback and destroys the aggregate device and tap.

Device-specific taps preserve the selected stream's format rather than requesting a stereo mixdown. The initial implementation accepts one or two channels of 32-bit floating-point PCM. Helpers are grouped by bundle path, bundle identifier, or parent process. FaceTime's `avconferenced` mapping is a special case and remains experimental.

The main-thread model polls once per second. It removes routes for exited apps, updates helper membership, and rebuilds routes after changes to output identity or sample rate. Startup, sleep, Reset, and normal Quit preserve the documented volume lifecycle.

## DSP invariants

- The UI maps slider position to gain with `gain = (percent / 100)³`. This cubic perceptual taper is independent of the output device; it does not claim to duplicate the device's macOS scalar-to-decibel mapping.
- DSP gain is clamped to `[0, 1]`; nonfinite gain values resolve to unity.
- Unity in the UI is a routing bypass, not merely multiplication by one.
- The callback performs no memory allocation, locks, Objective-C messaging, file access, or network access.
- Gain changes ramp over the callback buffer to reduce discontinuities.
- Channel mapping supports planar and interleaved buffers with matching channel counts.
- Unexpected channel layouts set a failure flag. The main-thread refresh removes the failed route and restores original audio.
- Cleanup stops and destroys the IO callback before releasing its state.

Changes to audio routing should preserve these invariants and fail visibly instead of displaying a working volume adjustment when the route is unavailable.

## Checks

An offline synthetic-buffer harness is provided:

```sh
./scripts/test.sh
```

It exercises unity sample preservation, attenuation, mute, gain clamping, ramps, planar/interleaved channel mapping, invalid layouts, and null input. It uses AddressSanitizer and UndefinedBehaviorSanitizer. It does not play or capture audio.

**Verification status:** the app has been compiled and launched, and the menu layout has been corrected. The offline harness was not completed during initial delivery, and live audio compatibility is not certified. The existence of tests does not imply they have passed.

Manual audio validation should cover app isolation, 100% bypass, mute, helper restarts, permission denial, output-device changes, sleep, quit, and crash recovery. Call-related tests should only be performed when the person using the Mac is ready for them.

## Contributing

Use a focused branch and describe the visible behavior being changed. Include the macOS version, output device, and relevant app when reporting an audio issue; do not include private call recordings or credentials.

Keep the interface small: open applications, attenuation controls, Reset, login preference, and Quit. Document any new permission or compatibility constraint. Report which build or test commands actually ran, and distinguish offline checks from listening tests.

## Apple API references

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
