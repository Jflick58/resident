#!/bin/sh
# Checks that just-bash runs inside a bare JavaScriptCore context, which is what
# an iOS app has (no Node, no browser). Bundles the browser build into one
# script, stubs the one Node module it imports, and runs a few commands in the
# system's `jsc` shell with the globals JavaScriptCore lacks filled in.
# Note: `jsc` on a Mac uses the JIT; an iOS app's JSContext does not, so this
# shows the code runs, not how fast it runs on a phone.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/justbash.iife.js"
printf 'import { Bash, defineCommand } from "just-bash/browser";\nglobalThis.JustBash = { Bash, defineCommand };\n' > _entry.mjs
printf 'export function gunzipSync(){ throw new Error("gzip is not available"); }\nexport function gzipSync(){ throw new Error("gzip is not available"); }\nexport const constants = {};\nexport default {};\n' > _zlib.mjs
npx --yes esbuild@0.24.0 _entry.mjs --bundle --format=iife --platform=browser --target=safari17 \
  --alias:node:zlib=./_zlib.mjs --outfile="$out" --log-level=error
rm -f _entry.mjs _zlib.mjs
/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc jsc-check/test.js -- "$out" jsc-check/poly.js
