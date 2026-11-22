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

## Siri, CarPlay and a locked phone

Phone GPS drives are owned by native code, `App/DriveRecorder.swift` (in the app target, next to `DriveIntents.swift`), so Siri and the car screen can start and finish a drive without the web app running, with the phone locked. Its plugin, `DriveRecorder`, is registered on the bridge by `DDBridgeViewController` (`SceneDelegate.swift`) rather than through a plugin package, because the Siri intents need to call the recorder directly. `AppDelegate` boots it on every launch.

- Siri intents (`DriveIntents.swift`) have `openAppWhenRun = false` and `authenticationPolicy = .alwaysAllowed`, so they run on a locked phone with no Face ID, as long as **Settings, Siri, Allow Siri When Locked** is on. Finishing always works that way. Starting with the phone locked needs location **Always**: iOS lets a "While Using" app start GPS only while it is on screen. The Drive screen's Hands-free panel asks for it (iOS asks once; after that it opens Settings). Without Always, Siri asks iOS to unlock and open the app and starts the drive there.
- A Bluetooth drive (RaceBox, Dragy) still lives in the web app, so Siri starting or finishing one asks to unlock first.
- Every fix goes to `Application Support/DriveRecorder/current.jsonl` as it arrives (file protection "until first unlock", so it can be written while locked). If the app is closed mid-drive, the next launch saves what was recorded.
- A drive finished natively is written to `finished/<id>.json` (raw fixes). `app.html` (`importNative`) builds it with the same code as a drive finished on screen (`makeDrive`: the same name by time of day, thinning, stats, 5 points and 100 m to keep it) and then acks it. The home privacy zone is applied when a drive is shared, so it covers these too.
- `app.html` picks up a drive it didn't start (`syncNative`, on launch, on every return to the screen and on the recorder's `changed` event) and shows it as a normal live drive. A drive started on the phone also goes through the recorder, and the page finishes it itself and tells the recorder to drop its copy (`cancel`).
- The page sends the recorder its settings (`config`: data source, vehicle, units, g-force on or off). The recorder measures g-force itself with Core Motion, so g still logs with the phone locked.
- Lost while nothing is on screen: the camera (iOS doesn't allow filming in the background), speed limit alerts and beeps, Follow a route, and the live map. They come back when the app is opened mid-drive (except the camera, which starts only with a drive started on the phone).
- CarPlay's Start and Finish go to the recorder first through `NotificationCenter` (`DDRecorderCommand`, `DDRecorderState`), so the plugin package and the app target don't import each other.

## CarPlay

`plugins/carplay` puts Dragon Drive on the car screen in Apple's **Driving Task** category: one list with Start drive / Finish drive (time and distance while recording, Finish asks to confirm) and Follow a route (the planned routes; picking one offers Navigate in Maps, which opens Apple Maps on the car screen with the route's stops plus points along its line, or Follow only, which shows it on the phone's drive screen as usual). The taps run the same code as the phone's buttons in `app.html` (`cpState()` and the `CARPLAY` listeners); the web app has to have been opened on the phone at least once since the phone started, otherwise the car screen asks for that.

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

Run `npm run sync` after every change to `app.html`, then build again. After a change to `package.json` (a plugin added or removed) run `npm install` first.

## Ship a build

1. Bump the version: target **App**, **General**, *Version* (1.0, 1.1, ...) and *Build* (1, 2, 3, ..., must go up on every upload).
2. Run destination *Any iOS Device (arm64)*, then **Product, Archive**.
3. In the Organizer: **Distribute App, App Store Connect, Upload**.
4. The build shows up in App Store Connect under TestFlight after processing (10 to 30 minutes). Install it on your phone with the TestFlight app before sending it to review.

See `APP_STORE.md` for the listing, privacy answers and review notes.
