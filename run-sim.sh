#!/bin/zsh
# Build, install and launch in a simulator, then take a screenshot.
#   ./run-sim.sh <screenshot-name> [seconds-to-wait] [launch args...]
# The simulator is "iPhone Duo" unless SIM names another, e.g. SIM="iPhone 17 Pro".
set -e
cd "$(dirname "$0")"
source tools/local-config.sh
name=$1; wait=${2:-4}; shift; shift 2>/dev/null || true
device=${SIM:-iPhone Duo}
xcodegen generate >/dev/null
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcodebuild -project Resident.xcodeproj -scheme Resident -destination "platform=iOS Simulator,name=$device" \
  -derivedDataPath DerivedData -skipMacroValidation -skipPackagePluginValidation build 2>&1 | grep -E "error:|BUILD" | sort -u
xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$device" DerivedData/Build/Products/Debug-iphonesimulator/Resident.app
xcrun simctl launch "$device" "$BUNDLE_ID" "$@" >/dev/null
sleep $wait
mkdir -p screenshots
# A folding phone has two screens and simctl will not pick one: take the inner
# (unfolded) screen as the main shot and the outer screen alongside it.
if ! xcrun simctl io "$device" screenshot screenshots/$name.png 2>/dev/null; then
  xcrun simctl io "$device" screenshot --display=3 screenshots/$name.png 2>/dev/null
  xcrun simctl io "$device" screenshot --display=1 screenshots/$name-outer.png 2>/dev/null
fi
