# Dragon Drive for iPhone

The iOS app is [Capacitor](https://capacitorjs.com) 8 around the same web app the site serves. `copy-web.sh` runs `../build.sh` and copies the built page, icons, fonts, MapLibre and the legal pages into `www/`; Capacitor bundles that folder into the app, so the app works offline and never depends on the website being up. There's still one source of truth: edit `../app.html` as before.

- Bundle ID: `com.itschefff.dragondrive` (set in `capacitor.config.json` and the Xcode project). It can't change after the first upload to App Store Connect.
- iPhone only for now (`TARGETED_DEVICE_FAMILY = 1`), so App Review needs iPhone screenshots only.
- Background GPS: the app's own plugin in `plugins/drive-location` (Swift, installed from `package.json` as `dragon-drive-location`, so `cap sync` adds it to the Xcode project like any other plugin). A drive keeps recording with the screen locked or another app open: `UIBackgroundModes: location`, `allowsBackgroundLocationUpdates`, the blue location pill, and on iOS 17+ a `CLBackgroundActivitySession`. It asks only for "While Using" location; that is enough for a drive started on screen to carry on in the background, so it never asks for "Always". iOS pauses the web view's JavaScript in the background, so a fix sent to JavaScript then is lost (that is why the first TestFlight build, which used `@capacitor-community/background-geolocation`, logged only the start and end of a drive). The plugin keeps every fix natively instead, and `app.html` collects them with `drain()` every second on screen, at once when the app comes back, and before a drive is saved.
- `copy-web.sh` also copies `@capacitor/core`'s `capacitor.js` into `www/` and loads it first in the app's `index.html` (not the website's). The page reaches every native plugin through `Capacitor.registerPlugin`, which only that file defines; without it `NATIVE` plugins are all missing and the app quietly uses the website's browser GPS, which is what builds 1 to 3 did.
- Other native plugins: `@capacitor-community/keep-awake` (screen stays on while recording) and `@capacitor-community/bluetooth-le` (RaceBox, Dragy and other Bluetooth GPS). `app.html` uses them only when `NATIVE` is true; the website is unchanged.
- Bluetooth: WKWebView has no Web Bluetooth, so `nativeBluetooth()` in `app.html` wraps the plugin in the few Web Bluetooth calls `connectDevice()` already makes; the RaceBox and NMEA parsers are shared with the website. The app picks devices from the plugin's own list (RaceBox filtered by name, Dragy and "other" unfiltered). While a Bluetooth device is recording, a location watcher also runs so iOS doesn't suspend the app when the screen locks (`bluetooth-central` is in the background modes too). Tested only against a simulated RaceBox; needs a real RaceBox and Dragy on an iPhone.
- The app has no service worker and no visit counter (GoatCounter runs only on dragondrive.turboloser.co).
- Links people share (invites, routes) and the sign-in email always point at https://dragondrive.turboloser.co.

## Build on the Mac

Needs Xcode 16 or later and Node 20 or later.

```sh
cd native
npm install
npm run sync      # builds index.html, copies it into www/, updates the Xcode project
npm run open      # opens ios/App/App.xcodeproj in Xcode
```

In Xcode: select the **App** target, **Signing & Capabilities**, tick *Automatically manage signing* and choose your team. Background Modes (Location updates) is already in `Info.plist`. Plug in the iPhone, pick it as the run destination, press Run.

Run `npm run sync` after every change to `app.html`, then build again. After a change to `package.json` (a plugin added or removed) run `npm install` first.

## Ship a build

1. Bump the version: target **App**, **General**, *Version* (1.0, 1.1, ...) and *Build* (1, 2, 3, ..., must go up on every upload).
2. Run destination *Any iOS Device (arm64)*, then **Product, Archive**.
3. In the Organizer: **Distribute App, App Store Connect, Upload**.
4. The build shows up in App Store Connect under TestFlight after processing (10 to 30 minutes). Install it on your phone with the TestFlight app before sending it to review.

See `APP_STORE.md` for the listing, privacy answers and review notes.
