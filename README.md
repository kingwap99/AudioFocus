# AudioFocus

AudioFocus is a macOS menu bar app that keeps audio attached to the last focused
application that was actually producing sound. Focusing a silent window does not
interrupt the current audible owner.

For Chrome and Firefox, companion extensions add window/tab-level focus. Only a
focused tab reported as `audible` becomes the new owner; silent tabs retain the
last audible tab.

> Experimental project. CoreAudio process taps require macOS 14.2 or newer.

## Features

- Keeps the last audible application as the audio owner.
- Does not switch when the newly focused application is silent.
- Mutes background processes through a private CoreAudio process tap, aggregate
  device, and IOProc.
- Treats browser helper processes as part of the foreground browser family.
- Lists foreground window titles and the complete muted app/process list.
- Shows a build timestamp and live audio-pipeline status in the menu.
- Chrome and Firefox extensions provide per-tab audible-focus control.
- Browser HTML audio/video fades over 450 ms before tab mute is applied.

## Requirements

- macOS 14.2+
- Swift 5.9+ / Xcode command line tools
- Accessibility permission for complete window-title enumeration

## Build

```bash
./build.sh
open AudioFocus.app
```

The build script generates `BuildInfo.swift`, compiles the Swift package, creates
the `.app` bundle, and applies an ad-hoc signature.

## Browser extensions

### Chrome

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Click **Load unpacked**.
4. Select `BrowserExtensions/chrome`.

### Firefox

1. Open `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on**.
3. Select `BrowserExtensions/firefox/manifest.json`.

Firefox removes temporary extensions after restart. Permanent distribution
requires Mozilla signing or an enterprise policy.

## How it works

The app enumerates CoreAudio process objects and checks
`kAudioProcessPropertyIsRunningOutput`. A new foreground application only becomes
the owner when its process family is outputting audio. Background process objects
are placed in a `CATapDescription` with muted behavior. The tap is attached to a
private aggregate device, and an IOProc keeps the tap active while discarding its
captured audio.

Browser extensions use the WebExtensions `Tab.audible` state. A silent focused tab
does not replace the previous owner. When an audible tab is selected, HTML media
elements are faded and all other managed tabs are muted.

## Limitations

- macOS process taps operate at process level, not browser tab level; browser
  extensions are required for tab control.
- WebAudio, DRM players, and restricted browser pages cannot expose their gain to
  content scripts. They fall back to tab mute without a gradual fade.
- General native macOS applications switch at process-tap boundaries; public
  CoreAudio APIs do not provide arbitrary per-process gain control.
- This project currently has no packaged notarized release.

## Project layout

```text
Sources/AudioFocus/       macOS menu bar app
BrowserExtensions/chrome Chrome extension
BrowserExtensions/firefox Firefox extension
build.sh                  app bundle builder
```
