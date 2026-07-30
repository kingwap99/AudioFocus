# AudioFocus browser extensions

The macOS app controls audio between applications. These companion extensions add
window/tab-level control inside Chrome and Firefox.

Behavior:

- A focused tab becomes the audio owner only when the browser reports it as `audible`.
- Focusing a silent tab or window does not replace the last audible owner.
- The previous owner fades out over 450 ms, then the browser's tab mute is enabled.
- The new owner is unmuted and its HTML `<audio>` / `<video>` elements fade in.
- WebAudio and protected browser pages cannot expose their gain to a content script;
  they use the final tab mute without a gradual fade.

## Chrome

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Click **Load unpacked**.
4. Select the `chrome` folder.

## Firefox

1. Open `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on**.
3. Select `firefox/manifest.json`.

Firefox removes temporary extensions when it restarts. Permanent installation
requires Mozilla signing or an enterprise policy.
