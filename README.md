# Roadbook

A Strava-style logbook for driving. Record a drive with your phone's GPS, see the route and stats, share drives in a feed with kudos and comments, and compare yourself on segments.

**Segments are ranked by smoothness, not speed.** Each pass is scored on gentle braking and steady acceleration; times are shown but never ranked. While a drive is recording, the app switches to a minimal "Eyes on the road" screen, and finishing a drive needs a one-second hold.

## Run it

It's a static, installable web app with no build tools.

- **Locally:** `python3 -m http.server` in this folder, then open http://localhost:8000. Browsers only allow GPS on `localhost` or HTTPS.
- **On your phone:** enable GitHub Pages (Settings → Pages → Deploy from a branch → `main` / root), open the Pages URL, then "Add to Home Screen".

No GPS handy? Tap **Drive → Simulate a drive** to replay a demo route.

## Files

| File | What it is |
| --- | --- |
| `app.html` | The whole app (markup, styles, script). Edit this one. |
| `build.sh` | Wraps `app.html` into `index.html` with the PWA head tags. Run `sh build.sh` after editing. |
| `index.html` | Generated page that gets served. |
| `manifest.webmanifest`, `sw.js`, `icon.svg` | Install metadata, offline cache, app icon. |

## Current limits

- Data lives on the device (localStorage). The other drivers you see are labelled example data.
- A real shared feed between friends needs a backend with accounts; that's the next step.
