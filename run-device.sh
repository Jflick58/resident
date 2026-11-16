#!/bin/zsh
# Build, sign, install and launch on a connected iPhone.
#   ./run-device.sh [launch args...]
# The team, the bundle ID and the phone come from Config/Local.xcconfig (copy
# Config/Local.xcconfig.example to make one), or from TEAM, BUNDLE_ID and
# DEVICE in the environment. Xcode must be signed in to the Apple account that
# owns the team (Xcode > Settings > Accounts).
# PERSONAL=1 signs for a free personal team, which may not use the increased
# memory limit: the app is then built without it and large models have less room.
set -e
cd "$(dirname "$0")"
source tools/local-config.sh
if [[ -z "$TEAM" || -z "$DEVICE" ]]; then
  echo "Set DEVELOPMENT_TEAM and RUN_DEVICE in Config/Local.xcconfig (see Config/Local.xcconfig.example)." >&2
  exit 1
fi
extra=()
[[ -n "$PERSONAL" ]] && extra=(CODE_SIGN_ENTITLEMENTS=)
xcodegen generate >/dev/null
xcodebuild -project Resident.xcodeproj -scheme Resident -destination "id=$DEVICE" \
  -derivedDataPath DerivedData -skipMacroValidation -skipPackagePluginValidation \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" APP_BUNDLE_ID="$BUNDLE_ID" $extra build 2>&1 \
  | grep -E "error:|BUILD" | sort -u
# A build that failed leaves no app, or an old one: stop instead of installing that.
[[ ${pipestatus[1]} -eq 0 ]] || exit 1
xcrun devicectl device install app --device "$DEVICE" DerivedData/Build/Products/Debug-iphoneos/Resident.app
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" "$@"
