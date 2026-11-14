# Using Volume Mixer

## First launch

Build the app using the instructions in the [README](../README.md), copy it to Applications, and open it. Volume Mixer runs in the menu bar without a Dock window. Its icon shows three sliders.

The list contains currently open applications with a regular macOS app presence. Background-only utilities and the mixer itself are excluded. The list refreshes once per second. Apps do not need to be playing audio to appear.

## Controls

| Control | Behavior |
| --- | --- |
| App slider | Sets linear gain from 0% to 100%. |
| Percentage | Shows the current requested volume. |
| Speaker button | Mutes the app; clicking again restores 100%, not its previous level. |
| Waveform indicator | Indicates that macOS reports active output audio for an associated process. |
| Reset | Removes all active routes and restores every app to 100%. |
| Open at login | Registers or unregisters the installed app as a macOS login item. |
| Quit | Removes active routes and exits, restoring original audio. |

**100% means the app's original audio, subject to its own volume controls and the Mac's master volume.** It does not turn the Mac's speakers up to maximum. The mixer never increases gain above the original signal.

At 100%, the mixer creates no audio route for that app. Below 100%, it captures the app's output using a private Core Audio process tap, applies attenuation, and plays it through the current default output. The original stream is muted only while the tap is active.

## Permissions

macOS may request system audio recording permission the first time you lower a slider. The permission allows the mixer to process outgoing app audio; the app does not write recordings or upload audio.

If permission was denied:

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**. Labels can vary by macOS version.
2. Allow **Volume Mixer** to capture system audio.
3. Quit and reopen Volume Mixer, then try the slider again.

Rebuilding an ad-hoc-signed app may invalidate its previous permission grant. Keep one installed copy in Applications to avoid confusing duplicate permission entries.

## Defaults and lifecycle

- Newly listed apps start at 100%.
- Closing and reopening an app resets its level once the mixer observes the process change.
- Relaunching Volume Mixer resets all app levels to 100%.
- Going to sleep resets all levels to 100%.
- Changing the default output or its sample rate rebuilds active routes using the selected levels.
- A detected route failure removes that route, resets its displayed level to 100%, and shows an explanation. Restoring the original signal can make a previously attenuated app louder.

## Troubleshooting

### An app says “Waiting for audio”

Its audio process has not appeared yet. Play audio in that app and allow a moment for the next refresh. The requested level is retained while waiting.

### A slider does not affect the sound

Check audio permission and ensure the app uses the Mac's default output. Some apps select their own output device. Try Reset, play audio, and lower the slider again. A sandboxed helper, protected stream, or unsupported device may not be controllable.

### FaceTime volume does not change

FaceTime media may run in Apple's `avconferenced` service. The mixer attempts to associate that service with FaceTime while FaceTime is open. This path has not been verified in a live call. The service can also be shared by other Apple calling features, so isolation is not guaranteed. The mixer does not disable macOS call-related audio ducking.

### An audio error appears

The app restores original audio rather than retaining a failed route. Check the permission entry, reconnect or select a supported output, and try again. Quit the mixer if you want all audio processing removed immediately.

### The menu-bar icon is missing

Open **Volume Mixer** from Applications. On a crowded menu bar, switch to an app with fewer menus or check any menu-bar hiding utility. If launching from source, build the `.app` bundle with `scripts/build.sh`; the raw executable is not the intended installation.

### Open at login does not work

Keep the app in Applications, enable **Open at login**, and check **System Settings → General → Login Items** if macOS requires approval. Moving or deleting the installed app can break its login entry.

## Known limitations

- Early release: end-to-end audio behavior has not been fully verified across apps and hardware.
- Supports the default output's first mono/stereo Float32 stream. Multichannel interfaces, protected audio, and apps using another output may not work.
- Helper grouping uses bundle identity, executable path, and process ancestry; unusual helpers may not map correctly.
- The polling interval can leave a brief delay when a new helper starts or an output device changes.
- macOS audio permissions, routing, or device failures can prevent attenuation.
- No saved per-app levels, EQ, amplification, per-app device selection, or call-ducking control.

## Uninstall

1. Turn off **Open at login**.
2. Click **Quit** in the mixer.
3. Move **Volume Mixer.app** from Applications to Trash.

No audio driver, privileged helper, or persistent aggregate device is installed. The source folder and build artifacts can be removed separately if you no longer need them.
