#!/bin/zsh
# Archives the app in the release configuration and uploads it to App Store Connect.
#   tools/app-store-upload.sh              archive, then upload
#   tools/app-store-upload.sh --archive    archive only
#   tools/app-store-upload.sh --upload     upload the last archive this script made
#
# The team and the bundle ID come from Config/Local.xcconfig, as for ./run-device.sh.
# The app must already have its record in App Store Connect (Apps > + > New App).
#
# Signing in, one of:
#   - An Apple account in Xcode > Settings > Accounts, with the Admin or Account Holder role.
#     Without one the upload stops at "No Accounts".
#   - An App Store Connect API key (Users and Access > Integrations), given as
#     ASC_KEY_PATH (the .p8 file), ASC_KEY_ID and ASC_ISSUER_ID.
#
# The archive goes where Xcode keeps its own, so it shows in Window > Organizer and can be
# uploaded from there as well. The export options hold the team ID, so they are written
# under DerivedData, which git ignores.
set -o pipefail
cd "$(dirname "$0")/.."
source tools/local-config.sh
work=DerivedData/AppStore
mkdir -p "$work"

if [[ "$1" != "--upload" ]]; then
  archive="$HOME/Library/Developer/Xcode/Archives/$(date "+%Y-%m-%d")/Resident $(date "+%Y-%m-%d %H.%M").xcarchive"
  mkdir -p "$(dirname "$archive")"
  xcodegen generate >/dev/null || { echo "xcodegen failed"; exit 1; }
  echo "Archiving $(git rev-parse --short HEAD)$([ -n "$(git status --porcelain)" ] && echo " with uncommitted changes")"
  xcodebuild -project Resident.xcodeproj -scheme Resident -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$archive" -derivedDataPath DerivedData \
    -skipMacroValidation -skipPackagePluginValidation -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" APP_BUNDLE_ID="$BUNDLE_ID" archive > "$work/archive.log" 2>&1 \
    || { grep -E "error:" "$work/archive.log" | sort -u | head -20; echo "The archive failed: $work/archive.log"; exit 2; }
  echo "$archive" > "$work/last-archive.txt"
  echo "Archived: $archive"
fi
[[ "$1" == "--archive" ]] && exit 0

archive=$(cat "$work/last-archive.txt" 2>/dev/null)
[[ -d "$archive" ]] || { echo "There is no archive to upload. Run this without --upload first."; exit 1; }
/usr/libexec/PlistBuddy -c "Clear dict" \
  -c "Add :method string app-store-connect" -c "Add :destination string upload" \
  -c "Add :teamID string $TEAM" -c "Add :signingStyle string automatic" \
  -c "Add :uploadSymbols bool true" -c "Add :manageAppVersionAndBuildNumber bool true" \
  "$work/ExportOptions.plist" >/dev/null
key=()
if [[ -n "$ASC_KEY_PATH" ]]; then
  key=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
echo "Uploading $(basename "$archive")"
rm -rf "$work/export"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions.plist" \
  -exportPath "$work/export" -allowProvisioningUpdates $key > "$work/upload.log" 2>&1
result=$?
grep -E "error:|EXPORT (SUCCEEDED|FAILED)|[Uu]pload (succeeded|failed)|Uploaded" "$work/upload.log" | sort -u | tail -12
if grep -q "No Accounts\|Failed to Use Accounts" "$work/upload.log"; then
  echo "Xcode has no Apple account it can use. Sign in under Xcode > Settings > Accounts, or give an API key (see the top of this script), then run: tools/app-store-upload.sh --upload"
fi
exit $result
