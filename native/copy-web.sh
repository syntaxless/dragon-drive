#!/bin/sh
# Copies the website's files into www/, which Capacitor bundles into the iOS app.
# The app runs these local copies, so it works offline and never shows a half-loaded site.
set -e
cd "$(dirname "$0")"
(cd .. && sh build.sh)
rm -rf www && mkdir -p www
for f in index.html manifest.webmanifest icon.svg apple-touch-icon.png icon-192.png icon-512.png privacy.html terms.html support.html; do
  cp "../$f" www/
done
cp -R ../vendor www/vendor
# The page needs Capacitor's JavaScript (window.Capacitor.registerPlugin) to reach the native plugins
# (background GPS, keep-awake, Bluetooth). Without it the app silently falls back to the website's
# browser GPS, which iOS pauses when the screen locks. Load it first, in the app's copy only.
cp node_modules/@capacitor/core/dist/capacitor.js www/capacitor.js
awk '{print} /<meta charset="utf-8">/ && !d {print "<script src=\"capacitor.js\"></script>"; d=1}' www/index.html > www/index.tmp && mv www/index.tmp www/index.html
grep -q '<script src="capacitor.js"></script>' www/index.html || { echo "capacitor.js was not added to www/index.html"; exit 1; }
echo "www/ ready"
