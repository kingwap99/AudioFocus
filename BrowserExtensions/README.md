# AudioFocus browser extensions

The macOS app controls audio between applications. These companion extensions add
window/tab-level control inside Chrome and Firefox.

Behavior:

- A focused tab becomes the audio owner only when the browser reports it as `audible`.
- Focusing a silent tab or window does not replace the last audible owner.
- The previous owner fades out over 450 ms, then the browser's tab mute is enabled.
- The new owner is unmuted and its HTML `<audio>` / `<video>` elements fade in.
- Fade-out stops at volume `0.01` rather than zero, so players such as Bilibili do
  not convert AudioFocus's transition into a persistent player-level mute.
- A new fade cancels any older animation for the same media element, preventing a
  stale fade-out from leaving a newly focused video at volume zero.
- WebAudio and protected browser pages cannot expose their gain to a content script;
  they use the final tab mute without a gradual fade.
- The switch delay is read from the AudioFocus menu through the bundled native
  messaging host and updates within about one second.
- Closing the owner waits 250 ms, then restores the foreground playing tab or the
  most recently focused managed tab that still reports active media playback.
- If the foreground player is still initializing, owner-close recovery retries
  every 250 ms for up to 2 seconds and checks every injected frame for media.
- When a browser loses foreground focus, AudioFocus fades and mutes its managed
  tabs. Returning to a silent active tab never restores a background tab or
  steals audio from another application.
- When an owner tab closes and its active replacement remains silent, the
  extension tells AudioFocus to restore the prior audible application owner.
- Re-selecting a managed tab uses its HTML media playback state even while Chrome
  or Firefox reports the muted tab as not `audible`.
- Returning to a browser immediately restores its existing playing owner so the
  macOS app can detect output and complete the application-level switch.
- The controller remains disabled until the native host confirms that the
  AudioFocus app is running.
- When AudioFocus exits, the extension restores tabs it faded or muted, clears
  ownership state, and disconnects its native-host process.
- If no safe replacement is available, all managed tabs remain muted until a new
  foreground tab actually becomes audible.

## Chrome

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Click **Load unpacked**.
4. Select the `chrome` folder.

If an older unpacked copy is installed, remove it first and load this folder again.
The current extension uses the fixed ID `pijagplcjlcnlgafkcegnbdjkgeoheak`.
The lifecycle-aware controller with previous-owner restoration is version `1.1.5`.

## Firefox

1. Open `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on**.
3. Select `firefox/manifest.json`.

Firefox removes temporary extensions when it restarts. Permanent installation
requires Mozilla signing or an enterprise policy.

AudioFocus installs the Chrome and Firefox native-host manifests when the app
starts. Reload the extension after replacing the app bundle.
