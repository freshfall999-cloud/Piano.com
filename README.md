# Piano Browser

A web browser for iPhone and iPad that gives web pages the **Web MIDI API**, which
Safari and every other iOS browser lack. Plug in a digital piano, keyboard, drum pad
or any other MIDI instrument and web apps that call `navigator.requestMIDIAccess()`
just work.

- **USB** instruments (USB-C cable, or Apple's Lightning to USB Camera Adapter) appear automatically.
- **Bluetooth MIDI** instruments are paired from the piano button in the toolbar.
- MIDI **in and out**: pages receive what you play and can send notes back to the instrument.
- Each website has to ask permission once before it can use your instruments.
- Sound keeps playing with the silent switch on, and the screen stays awake.
- Built-in test keyboard and MIDI monitor (⋯ → Test Keyboard) to check a connection.
- Full-screen mode, bookmarks, and a home page you can set to your piano app.

## Install on your iPhone

You need a Mac with Xcode 16 or newer. A free Apple ID is enough.

1. Open `PianoBrowser.xcodeproj` in Xcode.
2. Select the **PianoBrowser** target → **Signing & Capabilities**, choose your Team,
   and change the bundle identifier to something of your own (e.g. `com.yourname.PianoBrowser`).
3. Connect your iPhone, pick it as the run destination, and press **Run**.
4. First launch only: on the phone, trust the developer under
   Settings → General → VPN & Device Management.

With a free Apple ID the app has to be re-installed from Xcode every 7 days; a paid
developer account removes that limit.

## Using it with your piano app

Type your app's address in the address bar. Local dev servers work too
(`192.168.1.20:3000`, `my-mac.local:5173` — plain `http` is allowed).
Then ⋯ → **Set as Home Page** so it opens straight into your app.

Your page needs nothing special: standard Web MIDI code works unchanged.

```js
const midi = await navigator.requestMIDIAccess();
midi.inputs.forEach(input => {
  input.onmidimessage = e => console.log(e.data); // e.g. [144, 60, 100]
});
```

## How it works

| File | Role |
| --- | --- |
| `PianoBrowser/Web/WebMIDIPolyfill.js` | Injected into every page; implements `requestMIDIAccess`, `MIDIAccess`, `MIDIInput`, `MIDIOutput` and their events |
| `PianoBrowser/BrowserModel.swift` | Owns the `WKWebView`; passes messages between pages and CoreMIDI; per-site permission |
| `PianoBrowser/MIDIManager.swift` | CoreMIDI: listens to every source, sends to destinations, tracks hot-plugging |
| `PianoBrowser/ContentView.swift`, `InstrumentsView.swift` | Browser UI and the instruments sheet |
| `PianoBrowser/Web/start.html` | Start page with test keyboard and MIDI monitor |

`node tests/polyfill.test.js` runs the polyfill and start page in Chromium against a
fake native bridge (needs the `playwright` npm package).
