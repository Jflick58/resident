#!/bin/zsh
# Takes the screenshots the website uses, from the simulator, in dark mode.
#   tools/site-shots.sh
#   SIM="iPad Pro 13-inch (M5)" OUT=store/screenshots/ipad-13 tools/site-shots.sh   for the App Store
# They land in site/assets/img/ as shot-<name>.png, or in OUT at full size. The simulator holds no
# real data, so nothing private can end up on the site. Build the app for the
# simulator first (./run-sim.sh does).
cd "$(dirname "$0")/.."
source tools/local-config.sh
device=${SIM:-iPhone 18 Pro}
out=${OUT:-site/assets/img}
mkdir -p "$out"
# Every simulator command gets a time limit: a stuck simulator hangs them for good.
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }

limit 120 xcrun simctl boot "$device" 2>/dev/null
limit 240 xcrun simctl bootstatus "$device" -b >/dev/null 2>&1
limit 30 xcrun simctl ui "$device" appearance dark
limit 30 xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularMode active --cellularBars 4
limit 240 xcrun simctl install "$device" DerivedData/Build/Products/Debug-iphonesimulator/Resident.app || { echo "The simulator would not take the app."; exit 1; }
limit 30 xcrun simctl privacy "$device" grant microphone "$BUNDLE_ID"

shot() {
  local name=$1 wait=$2; shift 2
  limit 30 xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null
  limit 90 xcrun simctl launch "$device" "$BUNDLE_ID" "$@" >/dev/null || { echo "$name: the app did not launch"; return 1; }
  sleep $wait
  # Taken to a temporary file first, so a failed shot never replaces a good picture.
  # A folding phone has two screens and needs one named; the outer one is phone-shaped.
  local new=$(mktemp -t shot).png
  limit 40 xcrun simctl io "$device" screenshot $new >/dev/null 2>&1 \
    || limit 40 xcrun simctl io "$device" screenshot --display=1 $new >/dev/null 2>&1 \
    || { echo "$name: no screenshot"; return 1; }
  mv $new $out/shot-$name.png
  echo "$name: $(sips -g pixelWidth -g pixelHeight $out/shot-$name.png 2>/dev/null | awk '/pixel/ {printf "%s ", $2}')"
}

# The simulator cannot run a model, so each chat shown is one LFM3 really had, run on
# a Mac through the same agent and saved by the test tool:
#   harness-spike LiquidAI/LFM3-1.7B-MLX-6bit --thinking low --chat "<a>|<b>" --save tools/site-chat.json
# tools/site-pull-request.json was saved the same way with --repository jflick58/resident --live,
# which opened a real pull request (see evals/README.md). A chat is put in the app's data by
# itself, with LFM3 listed as the model on the device.
data="$(limit 30 xcrun simctl get_app_container "$device" "$BUNDLE_ID" data)/Library/Application Support/Harness"
limit 60 xcrun simctl launch "$device" "$BUNDLE_ID" >/dev/null; sleep 4
limit 30 xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null
seed() {  # seed <chat.json> <title>
  limit 30 xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null
  python3 -I - "$data" "$1" "$2" <<'SEED'
import glob, json, os, sys, uuid
data, chat, title = sys.argv[1], sys.argv[2], sys.argv[3]
agent = "A0000000-0000-4000-8000-000000000001"
model = {"repo": "LiquidAI/LFM3-1.7B-MLX-6bit", "name": "LFM3 1.7B", "sizeBytes": 1423163359, "contextTokens": 32768,
         "capabilities": {"tools": True, "thinking": True, "vision": False}}
old = os.path.join(data, "library.json")
if os.path.exists(old):
    kept = [m for m in json.load(open(old)).get("installed", []) if m["repo"] == model["repo"]]
    if kept: model = kept[0]
json.dump({"endpoints": [], "defaultPresetID": agent, "installed": [model], "selected": {"local": {"_0": model["repo"]}}}, open(old, "w"))
os.makedirs(os.path.join(data, "conversations"), exist_ok=True)
for path in glob.glob(os.path.join(data, "conversations", "*.json")): os.remove(path)
name = str(uuid.uuid4()).upper()
json.dump({"id": name, "title": title, "presetID": agent, "messages": json.load(open(chat)),
           "updatedAt": "2026-11-16T17:41:00Z", "isTitled": True}, open(os.path.join(data, "conversations", name + ".json"), "w"))
SEED
}
seed tools/site-chat.json "Latest Swift release"

# The status bar says 9:41, so the greeting is told it is morning.
shot home 7 -demoHour 9
shot models 6 -openSheet models
shot agents 6 -openSheet presets
shot settings 6 -openSheet settings
shot connectors 6 -openSheet addConnector
shot chat 6 -openLatestChat YES
if [ -f tools/site-pull-request.json ]; then
  seed tools/site-pull-request.json "Search limit"
  # Opened at its end: the pull request and the answer are what there is to see.
  shot pull-request 7 -openLatestChat YES -openAtEnd YES
fi
