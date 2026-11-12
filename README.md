# Dragon Drive

A Strava-style logbook for driving. Record a drive with your phone or a performance GPS, see the route, elevation and g-force, time your runs, share drives in a feed with kudos and comments, and post a share card with your photo.

Live at https://dragondrive.turboloser.co

## What it records

- **Every drive:** distance, moving and elapsed time, average and top speed, elevation gain and profile, max acceleration, braking and lateral g (with a friction-circle plot).
- **Timed runs**, detected automatically: 0–60 mph, 60–130 mph, 60 ft, ⅛ mile and ¼ mile (with trap speeds). Runs start when the car moves off from a stop (no rollout subtracted). Phone GPS logs about once a second, so those times are estimates; a 10–25 Hz device gives accurate ones.
- **Segments:** closed-course segments (tracks, drag strips) rank drivers by time. Public-road segments list passes without ranking, so nobody wins by speeding on open roads.
- **Map styles:** routes are drawn over vector street maps (MapLibre GL with free OpenFreeMap tiles, no API key) in Streets, Light, Dark, Monochrome or Blueprint styles, or over a plain grid or solid color. The choice applies to drive pages, the feed, the Routes tab and share cards. Inside the Claude preview only grid and solid color are available.
- **Photos and share cards:** attach a photo to a drive, then export a 1080 × 1350 card with the photo, route and key numbers.

## Data sources

| Source | How | Notes |
| --- | --- | --- |
| Phone GPS | Browser geolocation | About 1 Hz. Works everywhere, including iPhone. |
| Phone motion sensors | `devicemotion`, gravity removed | Peak horizontal g between GPS fixes. Mount the phone firmly. |
| RaceBox Mini / Mini S / Micro | Web Bluetooth, RaceBox BLE protocol (UBX-framed data message, class 0xFF id 0x01) | Position, speed, altitude and the device's own accelerometer at up to 25 Hz. |
| Dragy | Web Bluetooth, NMEA | Experimental. Dragy doesn't publish its protocol; we try standard NMEA sentences. Needs testing with a real unit. |
| Other Bluetooth GPS | Web Bluetooth, NMEA (RMC + GGA) | Any receiver that streams NMEA over a BLE serial service. |

Web Bluetooth works in Chrome and Edge on Android, Windows, macOS and ChromeOS. iPhone browsers don't support it, so on iPhone use Phone GPS.

## Run it

It's a static, installable web app with no build tools.

- **Locally:** `python3 -m http.server` in this folder, then open http://localhost:8000. Browsers only allow GPS and Bluetooth on `localhost` or HTTPS.
- **On your phone:** open the live site and use "Add to Home Screen".

No GPS handy? Tap **Drive**, then **Simulate a road drive** or **Simulate a drag-strip pass**.

## Files

| File | What it is |
| --- | --- |
| `app.html` | The whole app (markup, styles, script). Edit this one. |
| `build.sh` | Wraps `app.html` into `index.html` with the PWA head tags. Run `sh build.sh` after editing. |
| `index.html` | Generated page that gets served. |
| `manifest.webmanifest`, `sw.js`, `icon.svg` | Install metadata, offline cache, app icon. |
| `vendor/maplibre/` | MapLibre GL JS 4.7.1 (BSD-3-Clause), served locally so it works offline. |
| `CNAME` | Custom domain for GitHub Pages. |

## Current limits

- Drives live on the device (localStorage; photos in IndexedDB). The storage keys still say `roadtripper` on purpose, so drives recorded before the rename are kept. The other drivers you see are labelled example data.
- A real shared feed between friends needs a backend with accounts; that's the next step.

## Account sync (optional)

Sync uses a free [Supabase](https://supabase.com) project with email sign-in links. Until it's set up, the app stays device-only and the sync panel is hidden.

1. Create a Supabase project and run `supabase/setup.sql` in its SQL editor.
2. Authentication → URL Configuration: set Site URL to `https://dragondrive.turboloser.co` and add it to Redirect URLs.
3. Authentication → Email Templates → Magic Link: add `Or enter this code: {{ .Token }}` so people using the iPhone Home Screen app can type the code (links open in Safari, which keeps separate storage).
4. Copy the Project URL and the anon public key into `CLOUD` near the top of the script in `app.html`, then run `sh build.sh`.

Supabase's built-in email sender is rate-limited to a few emails an hour; add your own SMTP under Authentication → Emails before inviting friends.
