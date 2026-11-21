# Dragon Drive for iPhone

The iOS app is [Capacitor](https://capacitorjs.com) 8 around the same web app the site serves. `copy-web.sh` runs `../build.sh` and copies the built page, icons, fonts, MapLibre and the legal pages into `www/`; Capacitor bundles that folder into the app, so the app works offline and never depends on the website being up. There's still one source of truth: edit `../app.html` as before.

- Bundle ID: `com.itschefff.dragondrive` (set in `capacitor.config.json` and the Xcode project). It can't change after the first upload to App Store Connect.
- iPhone only for now (`TARGETED_DEVICE_FAMILY = 1`), so App Review needs iPhone screenshots only.
- Native plugins: `@capacitor-community/background-geolocation` (keeps a drive recording with the screen locked or another app open, `UIBackgroundModes: location`), `@capacitor-community/keep-awake` (screen stays on while recording) and `@capacitor-community/bluetooth-le` (RaceBox, Dragy and other Bluetooth GPS). `app.html` uses them only when `NATIVE` is true; the website is unchanged.
- Bluetooth: WKWebView has no Web Bluetooth, so `nativeBluetooth()` in `app.html` wraps the plugin in the few Web Bluetooth calls `connectDevice()` already makes; the RaceBox and NMEA parsers are shared with the website. The app picks devices from the plugin's own list (RaceBox filtered by name, Dragy and "other" unfiltered). While a Bluetooth device is recording, a location watcher also runs so iOS doesn't suspend the app when the screen locks (`bluetooth-central` is in the background modes too). Tested only against a simulated RaceBox; needs a real RaceBox and Dragy on an iPhone.
- The app has no service worker and no visit counter (GoatCounter runs only on dragondrive.turboloser.co).
- Links people share (invites, routes) and the sign-in email always point at https://dragondrive.turboloser.co.

## CarPlay

`plugins/carplay` puts Dragon Drive on the car screen in Apple's **Driving Task** category: one list with Start drive / Finish drive (time and distance while recording, Finish asks to confirm) and Follow a route (the planned routes; picking one shows it on the phone's drive screen as usual). The taps run the same code as the phone's buttons in `app.html` (`cpState()` and the `CARPLAY` listeners); the web app has to have been opened on the phone at least once since the phone started, otherwise the car screen asks for that.

- It needs Apple's CarPlay entitlement (`com.apple.developer.carplay-driving-task`), requested at https://developer.apple.com/contact/carplay. Until Apple grants it, Dragon Drive doesn't show up in a real car. Phone and TestFlight builds are unaffected meanwhile: the entitlement is only in `App/CarPlay-Simulator.entitlements`, used for Simulator builds (`CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]`).
- Try it in the Simulator: run on an iPhone simulator, then **I/O, External Displays, CarPlay**.
- Once it's granted: in the developer account add the CarPlay capability to the App ID `com.itschefff.dragondrive`, then add the key to a phone entitlements file (or point `CODE_SIGN_ENTITLEMENTS` at `App/CarPlay-Simulator.entitlements` for every SDK) and archive as usual.
- Apple's rules for this category: system templates only (no map or video on the car screen), two screens deep, and on-screen data refreshed at most every 10 seconds, so time and distance move in 10-second steps. Showing the route line on the car screen would need the Navigation category, which requires turn-by-turn directions.

## Build on the Mac

Needs Xcode 16 or later and Node 20 or later.

```sh
cd native
npm install
npm run sync      # builds index.html, copies it into www/, updates the Xcode project
npm run open      # opens ios/App/App.xcodeproj in Xcode
```

In Xcode: select the **App** target, **Signing & Capabilities**, tick *Automatically manage signing* and choose your team. Background Modes (Location updates) is already in `Info.plist`. Plug in the iPhone, pick it as the run destination, press Run.

Run `npm run sync` after every change to `app.html`, then build again.

## Ship a build

1. Bump the version: target **App**, **General**, *Version* (1.0, 1.1, ...) and *Build* (1, 2, 3, ..., must go up on every upload).
2. Run destination *Any iOS Device (arm64)*, then **Product, Archive**.
3. In the Organizer: **Distribute App, App Store Connect, Upload**.
4. The build shows up in App Store Connect under TestFlight after processing (10 to 30 minutes). Install it on your phone with the TestFlight app before sending it to review.

See `APP_STORE.md` for the listing, privacy answers and review notes.
