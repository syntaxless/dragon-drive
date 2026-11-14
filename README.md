# Dragon Drive

A Strava-style logbook for driving. Record a drive with your phone or a performance GPS, see the route, elevation and g-force, time your runs, share drives in a feed with kudos and comments, and post a share card with your photo.

Live at https://dragondrive.turboloser.co

## What it records

- **Every drive:** distance, moving and elapsed time, average and top speed, elevation gain and profile, max acceleration, braking and lateral g (with a friction-circle plot).
- **Timed runs**, detected automatically: 0–60 mph, 60–130 mph, 60 ft, ⅛ mile and ¼ mile (with trap speeds). Runs start when the car moves off from a stop (no rollout subtracted). Phone GPS logs about once a second, so those times are estimates; a 10–25 Hz device gives accurate ones.
- **Routes:** a map of every road you've driven, grouped by area. There are no leaderboards, so nobody is racing anyone on public roads.
- **Map styles:** routes are drawn over vector street maps (MapLibre GL with free OpenFreeMap tiles, no API key) in Streets, Light, Dark, Synthwave or Game Boy styles, or over a plain grid or solid color. The choice applies to drive pages, the feed, the Routes tab and share cards. Inside the Claude preview only grid and solid color are available.
- **Planned routes:** on the Routes tab, tap stops on a map to plan a route. Roads mode snaps each leg to streets with the free OSRM router (OpenStreetMap data); Straight mode joins stops directly for water, trails or tracks. Share a route by link or to followers, and anyone can tap Follow to get the same line on their driving screen.
- **Photos and share cards:** attach a photo to a drive, then export a 1080 × 1350 card with the photo, route, your avatar and key numbers.
- **Drive videos:** film the road while recording (exact sync), or import any clip and line it up; Dragon Drive burns in speed, g-force, the route, elevation, compass heading and timed runs and exports an MP4. Two looks (Dragon Drive and Retro HUD), four speed styles (bar, ring, needle, digital), and each widget can be turned off. The widgets come from [Video Overlay](https://github.com/syntaxless/video-overlay). Where the browser has WebCodecs (recent Safari, Chrome, Edge), export re-encodes the clip frame by frame, faster than real time and with the original audio; otherwise it plays the clip once and records it.
- **Accounts:** email sign-in syncs profile, garage, drives and photos across devices and unlocks following friends. Sign out and in to switch accounts; each account's data stays separate on the phone.

## Data sources

| Source | How | Notes |
| --- | --- | --- |
| Phone GPS | Browser geolocation | About 1 Hz. Works everywhere, including iPhone. |
| Phone motion sensors | `devicemotion`, gravity removed | Peak horizontal g between GPS fixes. Mount the phone firmly. |
| RaceBox Mini / Mini S / Micro | Web Bluetooth, RaceBox BLE protocol (UBX-framed data message, class 0xFF id 0x01) | Position, speed, altitude and the device's own accelerometer at up to 25 Hz. |
| GoPro (HERO5 and later with GPS) | Import the MP4. The app reads the GPMF telemetry track (GPS5, or GPS9 on HERO11+) straight from the file | Route, speed and altitude at up to 18 Hz, plus the GoPro clock to line the video up exactly for the overlay. Nothing is uploaded. |
| Dragy | Web Bluetooth, NMEA | Experimental. Dragy doesn't publish its protocol; we try standard NMEA sentences. Needs testing with a real unit. |
| Other Bluetooth GPS | Web Bluetooth, NMEA (RMC + GGA) | Any receiver that streams NMEA over a BLE serial service. |

Web Bluetooth works in Chrome and Edge on Android, Windows, macOS and ChromeOS. iPhone browsers don't support it, so on iPhone use Phone GPS.

## Run it

It's a static, installable web app with no build tools.

- **Locally:** `python3 -m http.server` in this folder, then open http://localhost:8000. Browsers only allow GPS and Bluetooth on `localhost` or HTTPS.
- **On your phone:** open the live site and use "Add to Home Screen".


## Files

| File | What it is |
| --- | --- |
| `app.html` | The whole app (markup, styles, script). Edit this one. |
| `build.sh` | Wraps `app.html` into `index.html` with the PWA head tags. Run `sh build.sh` after editing. |
| `index.html` | Generated page that gets served. |
| `manifest.webmanifest`, `sw.js`, `icon.svg` | Install metadata, offline cache, app icon. |
| `icon-256.png` | PNG of the icon for emails. |
| `supabase/` | Database setup and Burnout's sign-in email template. |
| `vendor/maplibre/` | MapLibre GL JS 4.7.1 (BSD-3-Clause), served locally so it works offline. |
| `vendor/mediabunny/` | Mediabunny 1.61.3 (MPL-2.0), unmodified, loaded only when a video is exported. |
| `CNAME` | Custom domain for GitHub Pages. |

## Current limits

- Drives live on the device (localStorage; photos and videos in IndexedDB) and sync through your account if you sign in. Videos stay on the device that filmed them. The storage keys still say `roadtripper` on purpose, so drives recorded before the rename are kept. The other drivers you see are labelled example data.
- The feed shows your drives and the examples; seeing friends' drives needs a shared feed on top of the account backend.

## Account sync (optional)

Sync uses a free [Supabase](https://supabase.com) project with email sign-in links. Until it's set up, the app stays device-only and the sync panel is hidden.

1. Create a Supabase project and run `supabase/setup.sql` in its SQL editor.
2. Authentication → URL Configuration: set Site URL to `https://dragondrive.turboloser.co` and add it to Redirect URLs.
3. Authentication → Email Templates → Magic Link: paste `supabase/magic-link-email.html` (subject "Your keys, from Burnout 🔥"). It includes the `{{ .Token }}` code so people using the iPhone Home Screen app can type it (links open in Safari, which keeps separate storage).
4. Copy the Project URL and the anon public key into `CLOUD` near the top of the script in `app.html`, then run `sh build.sh`.

**Social features** (profiles, following, shared drives, kudos, comments, public garage): run `supabase/social.sql` in the SQL editor after `setup.sql`. Visibility rules live in the database, so the app can't show a drive to someone who isn't allowed to see it.
   Then run `supabase/vehicle-pages.sql` (vehicle descriptions and extra photos). New projects get it from social.sql already.
   Also run `supabase/follow-burnout.sql` (everyone follows @burnout) and `supabase/announcements.sql` (verified accounts can post announcements to every feed). Then `supabase/routes.sql` (planned routes you can share so a cruise follows the same line) and `supabase/stats-dashboard.sql` (a stats panel for verified accounts at the top of the feed). social.sql already includes all of these for new projects.

**Signup emails to Burnout** (optional): store the Resend API key in the Vault with `select vault.create_secret('re_…', 'resend_api_key');`, then run `supabase/signup-email.sql`. Every time someone picks their @handle, burnout@turboloser.co gets "@handle has signed up!" with a link to their profile.

Supabase's built-in email sender is rate-limited to a few emails an hour and can't change the From name. To send as Burnout, add custom SMTP under Authentication → Emails (e.g. Resend, free tier) with sender name `Burnout from Dragon Drive` and an address like `burnout@turboloser.co`; the email provider will ask you to add a couple of DNS records for turboloser.co.
