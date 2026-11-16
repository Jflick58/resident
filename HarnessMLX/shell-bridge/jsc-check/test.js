load(arguments[1]); // polyfills
load(arguments[0]);
const { Bash, defineCommand } = globalThis.JustBash;
const hello = defineCommand("calendar", async (args, ctx) => ({ stdout: "evt_201 09:30 Dentist\nevt_202 13:00 Lunch\n", stderr: "", exitCode: 0 }));
const bash = new Bash({ customCommands: [hello] });
(async () => {
  for (const cmd of [
    'echo $((1234*5678+91))',
    'calendar list tomorrow | grep -c evt',
    'calendar list > /tmp/c.txt; awk \'{print $2}\' /tmp/c.txt | head -1',
    'echo \'{"a":[1,2,3]}\' | jq ".a | length"',
    'printf "b\\na\\n" | sort | sed "s/a/A/"; date +%Y >/dev/null && echo dateok',
  ]) {
    const t = Date.now();
    const r = await bash.exec(cmd);
    print(JSON.stringify({ cmd, out: r.stdout, err: r.stderr.slice(0,200), code: r.exitCode, ms: Date.now() - t }));
  }
print("polyfilled: " + missing.join(", "));})().catch(e => print("FAILED " + e + "\n" + (e.stack||"")));
