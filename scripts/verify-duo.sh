#!/bin/zsh
# Build Maho Notes with Xcode 27.1+ and run it on the iPhone Duo simulator,
# capturing both displays.
#
# Xcode 27.0 has no iPhone Duo device type; the first Xcode that does is
# Xcode 27.1 RC (27A9275, 2026-10-05). Install it side by side (for example as
# /Applications/Xcode-beta.app) and run:
#
#     scripts/verify-duo.sh [/path/to/Xcode-27.1.app]
#
# The script picks the first installed Xcode that ships a Duo device type when
# no path is given. Output (DerivedData + screenshots) goes to build/duo/,
# which is gitignored. Poses (Closed / Book / Open / Rotate) are only
# switchable from Xcode's Device Hub, so re-run the two screenshot commands
# printed at the end after each pose change.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/build/duo}"
SIM_NAME="Maho Duo Check"

profiles_have_duo() {
  ls "$1/Contents/Developer/Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes" 2>/dev/null | grep -qi duo
}

XCODE_APP="${1:-}"
if [[ -z "$XCODE_APP" ]]; then
  for candidate in /Applications/Xcode*.app; do
    if profiles_have_duo "$candidate"; then XCODE_APP="$candidate"; break; fi
  done
fi
if [[ -z "$XCODE_APP" ]] || ! profiles_have_duo "$XCODE_APP"; then
  echo "error: no installed Xcode ships an iPhone Duo simulator device type." >&2
  echo "       Install Xcode 27.1 RC (27A9275) or later from" >&2
  echo "       https://developer.apple.com/download/applications/ and re-run" >&2
  echo "       scripts/verify-duo.sh /Applications/Xcode-beta.app" >&2
  exit 2
fi
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
echo "Using $(xcodebuild -version | tr '\n' ' ')from $XCODE_APP"

DUO_TYPE="$(xcrun simctl list devicetypes | grep -i 'iPhone Duo' | head -1 \
  | sed -E 's/.*\((com\.apple\.CoreSimulator\.SimDeviceType\.[^)]+)\).*/\1/')"
[[ -n "$DUO_TYPE" ]] || { echo "error: simctl lists no iPhone Duo device type" >&2; exit 2; }

newest_runtime() {
  # iOS 27.1 or newer; Duo needs the 27.1 runtime.
  xcrun simctl list runtimes | grep -E '^iOS (27\.[1-9]|2[89]|[3-9][0-9])' | tail -1 \
    | sed -E 's/.*(com\.apple\.CoreSimulator\.SimRuntime\.[^ ]+).*/\1/'
}
RUNTIME="$(newest_runtime)"
if [[ -z "$RUNTIME" ]]; then
  echo "No iOS 27.1+ simulator runtime installed; downloading it (several GB)..."
  xcodebuild -downloadPlatform iOS
  RUNTIME="$(newest_runtime)"
  [[ -n "$RUNTIME" ]] || { echo "error: iOS 27.1+ runtime still missing" >&2; exit 2; }
fi

UDID="$(xcrun simctl list devices | grep "$SIM_NAME (" | head -1 \
  | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl create "$SIM_NAME" "$DUO_TYPE" "$RUNTIME")"
  echo "Created simulator $SIM_NAME ($UDID)"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

mkdir -p "$OUT"
( cd "$ROOT/App" && xcodegen generate >/dev/null )
xcodebuild -project "$ROOT/App/MahoNotes.xcodeproj" -scheme MahoNotes_iOS \
  -destination "id=$UDID" -derivedDataPath "$OUT/DerivedData" \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build > "$OUT/build.log" 2>&1 \
  || { tail -30 "$OUT/build.log"; echo "error: build failed, see $OUT/build.log" >&2; exit 1; }
APP="$OUT/DerivedData/Build/Products/Debug-iphonesimulator/Maho Notes.app"
echo "SDK stamp:"; otool -l "$APP/Maho Notes" | grep -A4 LC_BUILD_VERSION | grep -E 'minos|sdk' | sed 's/^/  /'

xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" dev.pcca.mahonotes >/dev/null
sleep 10
# Outer display is "primary"; inner display is "primary-1" on the 27.1 simulator.
xcrun simctl io "$UDID" screenshot --display=primary   "$OUT/duo-outer.png" || true
xcrun simctl io "$UDID" screenshot --display=primary-1 "$OUT/duo-inner.png" || true
echo "Screenshots written to $OUT (duo-outer.png, duo-inner.png)."
echo "Change pose in Device Hub (Closed / Book / Open / Rotate Right), then re-run:"
echo "  xcrun simctl io $UDID screenshot --display=primary   <outer.png>"
echo "  xcrun simctl io $UDID screenshot --display=primary-1 <inner.png>"
