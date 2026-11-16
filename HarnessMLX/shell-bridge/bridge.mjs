// Runs just-bash (a bash interpreter with an in-memory file system) for the
// spike, speaking JSON lines on stdin/stdout:
//
//   in   {"type":"exec","command":"..."}           run a script
//   out  {"type":"call","id":1,"name":"search","args":[...],"stdin":""}
//        a custom command was invoked; the host runs it and answers with
//   in   {"type":"result","id":1,"stdout":"...","stderr":"","exitCode":0}
//   out  {"type":"done","stdout":"...","stderr":"...","exitCode":0}
//
// Custom command names are the process arguments. The host owns what they do.
import { Bash, defineCommand } from "just-bash";
import readline from "node:readline";

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const pending = new Map();
let sequence = 0;

const commands = process.argv.slice(2).map((name) =>
  defineCommand(name, async (args, context) => {
    const id = ++sequence;
    const answer = new Promise((resolve) => pending.set(id, resolve));
    send({ type: "call", id, name, args, stdin: context.stdin ?? "" });
    const result = await answer;
    return { stdout: result.stdout ?? "", stderr: result.stderr ?? "", exitCode: result.exitCode ?? 0 };
  }),
);

const bash = new Bash({ customCommands: commands, cwd: "/home/user" });

readline.createInterface({ input: process.stdin }).on("line", async (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message.type === "result") {
    pending.get(message.id)?.(message);
    pending.delete(message.id);
  } else if (message.type === "exec") {
    try {
      const result = await bash.exec(message.command);
      send({ type: "done", stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode });
    } catch (error) {
      send({ type: "done", stdout: "", stderr: String(error?.message ?? error), exitCode: 1 });
    }
  }
});
