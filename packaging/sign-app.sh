#!/bin/bash
# Sign Tusk.app with a Developer ID, inside-out.
#
#   sign-app.sh <app> <signing-identity> <entitlements>
#
# Order is not cosmetic: codesign SEALS whatever it finds inside the bundle, so the
# nested code (vendored dylibs, then the embedded CLI) must be signed before the
# outer bundle. Signing the bundle first would seal unsigned libraries and fail
# notarization. Apple explicitly advises against --deep for distribution.
#
# This must also run AFTER any install_name_tool rewriting, which invalidates code
# signatures — and on Apple Silicon an invalid signature is fatal, not a warning.
set -euo pipefail

APP="$1"
IDENTITY="$2"
ENTITLEMENTS="$3"

for lib in "$APP"/Contents/Frameworks/*.dylib; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$lib"
done

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/tuskcli"

codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

codesign --verify --strict "$APP"
