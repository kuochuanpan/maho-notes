#!/bin/zsh
# Build Maho Notes with Xcode 27.1+ and run it on the iPhone Duo simulator,
# capturing both displays.
#
# Xcode 27.0 has no iPhone Duo device type; the first Xcode that does is
# Xcode 27.1 RC (27A9275, 2026-10-05). Xcode 27.2 beta lists the device type
# too, but its own iOS 27.2 beta simulator runtimes (24B5084k, 24B5089g) name
# iPhone Duo (iPhone19,4) under `unsupportedDeviceTypes`, so creating a Duo
# device on them fails with "Incompatible device". The Duo simulator therefore
# needs the iOS 27.1 runtime (RC build 24A94232); the script downloads it when
# no installed runtime supports Duo (~7.9 GB).
#
# Since Xcode 27 the device-type profiles live system-wide in
# /Library/Developer/CoreSimulator/Profiles/DeviceTypes (installed by Xcode's
# first-launch components), not inside the Xcode bundle, so detection goes
# through `simctl`. Install a Duo-capable Xcode side by side (for example as
# /Applications/Xcode-beta.app) and run:
#
#     scripts/verify-duo.sh [/path/to/Xcode-27.1-or-later.app]
#
# The script picks the first installed Xcode whose simctl lists a Duo device
# type when no path is given. Output (DerivedData + screenshots) goes to
# build/duo/, which is gitignored. Poses (Closed / Book / Open / Rotate) are
# only switchable from Xcode's Device Hub, so re-run the two screenshot
# commands printed at the end after each pose change.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/build/duo}"
SIM_NAME="Maho Duo Check"
DUO_RUNTIME_BUILD="24A94232"   # iOS 27.1 RC simulator runtime

xcode_has_duo() {
  DEVELOPER_DIR="$1/Contents/Developer" xcrun simctl list devicetypes 2>/dev/null \
    | grep -q 'SimDeviceType\.iPhone-Duo'
}

XCODE_APP="${1:-}"
if [[ -z "$XCODE_APP" ]]; then
  for candidate in /Applications/Xcode*.app; do
    if xcode_has_duo "$candidate"; then XCODE_APP="$candidate"; break; fi
  done
fi
if [[ -z "$XCODE_APP" ]] || ! xcode_has_duo "$XCODE_APP"; then
  echo "error: no installed Xcode lists an iPhone Duo simulator device type." >&2
  echo "       Install Xcode 27.1 RC (27A9275) or later from" >&2
  echo "       https://developer.apple.com/download/applications/, launch it once" >&2
  echo "       so it installs its simulator components, then re-run" >&2
  echo "       scripts/verify-duo.sh /Applications/Xcode-beta.app" >&2
  exit 2
fi
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
# Always go through xcrun: a bare `xcodebuild` may resolve to another Xcode's
# usr/bin on PATH and ignore DEVELOPER_DIR, silently building with that SDK.
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
echo "Using $("$XCODEBUILD" -version | tr '\n' ' ')from $XCODE_APP"

DUO_TYPE="$(xcrun simctl list devicetypes | grep -i 'iPhone Duo' | head -1 \
  | sed -E 's/.*\((com\.apple\.CoreSimulator\.SimDeviceType\.[^)]+)\).*/\1/')"
[[ -n "$DUO_TYPE" ]] || { echo "error: simctl lists no iPhone Duo device type" >&2; exit 2; }

duo_runtime() {
  # Newest installed iOS runtime that actually lists iPhone Duo as a supported
  # device type. A plain version check is not enough: the 27.2 beta runtimes
  # are newer than 27.1 yet blacklist Duo.
  xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"]
       if r.get("isAvailable") and r.get("platform") == "iOS"
       and any(d["identifier"].endswith(".iPhone-Duo") for d in r.get("supportedDeviceTypes", []))]
rts.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rts[-1]["identifier"] if rts else "")
'
}
RUNTIME="$(duo_runtime)"
if [[ -z "$RUNTIME" ]]; then
  echo "No installed iOS simulator runtime supports iPhone Duo; downloading"
  echo "iOS 27.1 RC ($DUO_RUNTIME_BUILD, ~7.9 GB)..."
  "$XCODEBUILD" -downloadPlatform iOS -buildVersion "$DUO_RUNTIME_BUILD"
  RUNTIME="$(duo_runtime)"
  [[ -n "$RUNTIME" ]] || { echo "error: still no iOS runtime that supports iPhone Duo" >&2; exit 2; }
fi
echo "Runtime: $RUNTIME"

UDID="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
rt, name = sys.argv[1], sys.argv[2]
for d in json.load(sys.stdin)["devices"].get(rt, []):
    if d["name"] == name and d.get("isAvailable"):
        print(d["udid"]); break
' "$RUNTIME" "$SIM_NAME")"
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl create "$SIM_NAME" "$DUO_TYPE" "$RUNTIME")"
  echo "Created simulator $SIM_NAME ($UDID)"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

mkdir -p "$OUT"
( cd "$ROOT/App" && xcodegen generate >/dev/null )
"$XCODEBUILD" -project "$ROOT/App/MahoNotes.xcodeproj" -scheme MahoNotes_iOS \
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
