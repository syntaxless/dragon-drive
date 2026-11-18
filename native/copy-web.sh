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
echo "www/ ready"
