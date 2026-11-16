# Sourced by the run scripts: reads Config/Local.xcconfig (and the shared file
# for defaults) into shell variables. A variable already set in the
# environment wins, so `TEAM=… ./run-device.sh` still works.
setting() {
  local value
  for file in Config/Local.xcconfig Config/Shared.xcconfig; do
    [[ -f $file ]] || continue
    value=$(sed -n "s|^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$|\1|p" $file | tail -1)
    [[ -n "$value" ]] && { print -r -- "$value"; return; }
  done
}
: ${TEAM:=$(setting DEVELOPMENT_TEAM)}
: ${DEVICE:=$(setting RUN_DEVICE)}
: ${BUNDLE_ID:=$(setting APP_BUNDLE_ID)}
