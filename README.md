# Piano Browser

A web browser for iPhone and iPad that looks and works like Safari, and gives web
pages the **Web MIDI API**, which Safari and every other iOS browser lack. Plug in a
digital piano, keyboard, drum pad or any other MIDI instrument and web apps that call
`navigator.requestMIDIAccess()` just work.

**Browser**

- Safari's layout: the page fills the screen, with a floating address bar and toolbar (back, forward,
  share, bookmarks, tabs) over the bottom edge. The bar shrinks to the site name as you scroll down.
- Tabs with a tab grid, private tabs, swipe across the address bar to change tab, and tabs restored on the next launch.
- The address bar searches or opens addresses, with suggestions from bookmarks and history.
- Start page with favorites, bookmarks, history, find on page, desktop-site mode, downloads (saved to Files), hide toolbar.
- Links that open new windows, sign-in prompts, pull to refresh and swipe back/forward all behave as in Safari.

**Protection** (Settings → Block Unsafe and Adult Websites, on by default)

- Every website is checked against [Cloudflare for Families](https://developers.cloudflare.com/1.1.1.1/setup/#1111-for-families)
  before it opens; sites listed for malware, phishing or adult content get a "blocked" page instead.
  Only the website's name is sent for the check, over an encrypted connection.
- Safe search is forced on in Google, Bing, DuckDuckGo and Yahoo.
- WebKit's fraudulent-website warning is always on.
- Limits: the check is per website, so an allowed site can still show images hosted elsewhere, and
  sites with mixed content (social networks, video sites) are not filtered page by page. If the
  filter can't be reached, pages load unchecked. The switch is not passcode-protected.

**Privacy** (Settings → Block Trackers and Ads, on by default)

- About 3,600 known tracker and ad servers are blocked from loading inside other websites: a built-in list
  (`PianoBrowser/Web/Trackers.txt`) plus [Peter Lowe's list](https://pgl.yoyo.org/adservers/), refreshed weekly.
  A site that breaks can be exempted from the address bar menu.
- Click-tracking tags (`utm_…`, `fbclid`, `gclid`, …) are removed from links, and websites are sent the
  Global Privacy Control signal.
- Plain `http` addresses are tried over encrypted `https` first; a site that has no https still opens, marked "Not Secure".
- WebKit's cross-site tracking prevention (no third-party cookies) is on, as in Safari.
- Bookmarks, history and open tabs are stored with iOS "complete" file protection, so they are encrypted
  whenever the device is locked. Private tabs keep nothing.
- Limits: this reduces tracking, it does not make you anonymous. Websites and your network still see your IP
  address (iCloud Private Relay or a VPN hides that), the site you visit can still track what you do on it,
  and trackers not on the lists get through.

**Instruments**

- **USB** instruments (USB-C cable, or Apple's Lightning to USB Camera Adapter) appear automatically.
- **Bluetooth MIDI** instruments are paired from Instruments in the address bar menu (the **AA** button).
- MIDI **in and out**: pages receive what you play and can send notes back to the instrument.
- Each website has to ask permission once before it can use your instruments.
- Sound keeps playing with the silent switch on, and the screen stays awake.
- Built-in test keyboard and MIDI monitor to check a connection.

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
Then the **AA** button in the address bar → **Set as Home Page** so every new tab opens your app.

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
| `PianoBrowser/Browser.swift` | Tabs, bookmarks, history, settings; passes MIDI messages between pages and CoreMIDI; per-site MIDI permission |
| `PianoBrowser/Tab.swift` | One tab's `WKWebView`: navigation, filtering, downloads, dialogs |
| `PianoBrowser/SiteFilter.swift` | Website check against the family DNS filter, safe search, https upgrade, tracking-tag removal |
| `PianoBrowser/TrackerBlocker.swift` | Builds and installs the tracker/ad block list |
| `PianoBrowser/Storage.swift` | Encrypted-at-rest storage for bookmarks, history and tabs |
| `PianoBrowser/MIDIManager.swift` | CoreMIDI: listens to every source, sends to destinations, tracks hot-plugging |
| `PianoBrowser/*View.swift` | The interface: browser window, start page, tab grid, bookmarks/history, settings, instruments |
| `PianoBrowser/Web/start.html` | Test keyboard and MIDI monitor |

`node tests/polyfill.test.js` runs the polyfill and start page in Chromium against a
fake native bridge (needs the `playwright` npm package).
