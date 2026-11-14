# Volume Mixer

A small macOS menu-bar app for turning down individual open applications.

- Only currently open, regular applications appear; audio helpers are grouped under their app.
- Every app starts at **100%**. There is no amplification, EQ, or master-volume adjustment.
- **100% is a true bypass:** the app's audio is not captured or replayed. A private Core Audio process tap is created only below 100% and removed when restored to 100%.
- Sliders range from 0% (mute) to 100% (original volume). Percentages are linear sample gain, not perceived loudness.
- Reset restores all apps. Quit removes all audio routes. An app that quits and reopens starts at 100%.
- Optional **Open at login** toggle.

## Build and run

Requires macOS **14.4+** and Swift 6 command-line tools. No third-party packages or audio driver are installed.

```sh
./scripts/build.sh
open "dist/Volume Mixer.app"
```

For a stable installation, copy `dist/Volume Mixer.app` into `/Applications`, launch that copy, and enable **Open at login** if desired. Look for the three-slider icon in the menu bar.

macOS will request system audio capture permission the first time you lower an app's volume. This is needed to attenuate and replay that app's audio. Audio stays in memory on your Mac; it is never recorded to a file or uploaded. If denied, allow Volume Mixer in **System Settings → Privacy & Security → Screen & System Audio Recording** and reopen the app.

The local build is ad-hoc signed, not Developer ID signed or notarized. Rebuilding can cause macOS to request permission again.

## Scope and limitations

This is an initial build, not a fully audio-tested release. FaceTime call testing is intentionally left to the user.

- Targets the current default output's first mono/stereo Float32 stream. Apps explicitly routed to another output and multichannel/protected audio may not be controlled.
- Chromium/Electron helpers are matched by bundle path and process ancestry. `avconferenced` is associated with FaceTime while FaceTime is open; this service can be shared with other Apple calling features, so call behavior needs manual verification.
- Inactive apps may show “Waiting for audio.” The list and helper mapping refresh once per second.
- Changing output devices rebuilds active routes. Sleep resets all levels to 100%.
- Hardware/audio failures restore original volume and show an error. Original audio returns when routes stop; an error can therefore make an attenuated app louder again.
- The app does not alter macOS call ducking or volume settings inside another app.

## Development

SwiftUI supplies the menu-bar UI; Objective-C manages Core Audio taps and private aggregate devices. The real-time callback uses a bounded linear gain ramp and performs no allocation, Objective-C messaging, logging, or locking. Gain is clamped to `[0, 1]`.

An offline synthetic-buffer test harness is included for attenuation, channel mapping, and bounds checks:

```sh
./scripts/test.sh
```

It does not play or capture user audio. The initial delivery was built without completing this test harness, at the user's request.

## Remove

Turn off **Open at login**, quit Volume Mixer, and move the app to Trash. No persistent audio driver or background helper needs uninstalling.

## API references

- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple: CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
