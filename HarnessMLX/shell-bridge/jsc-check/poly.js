// What a bare JavaScriptCore context lacks. In the app these would be backed natively.
var missing = [];
function need(name, value) { if (typeof globalThis[name] === "undefined") { missing.push(name); globalThis[name] = value; } }
let timerId = 0; const cancelled = new Set();
need("setTimeout", (fn, ms, ...a) => { const id = ++timerId; Promise.resolve().then(() => { if (!cancelled.has(id)) fn(...a); }); return id; });
need("clearTimeout", (id) => cancelled.add(id));
need("setInterval", () => ++timerId);
need("clearInterval", () => {});
need("setImmediate", (fn, ...a) => globalThis.setTimeout(fn, 0, ...a));
need("queueMicrotask", (fn) => Promise.resolve().then(fn));
need("performance", { now: () => Date.now() });
need("console", { log: print, warn: print, error: print, debug() {}, info: print });
need("TextEncoder", class { encode(s) { const u = unescape(encodeURIComponent(s)); const a = new Uint8Array(u.length); for (let i = 0; i < u.length; i++) a[i] = u.charCodeAt(i); return a; } });
need("TextDecoder", class { decode(a) { if (!a) return ""; a = new Uint8Array(a.buffer || a, a.byteOffset || 0, a.byteLength); let s = ""; for (let i = 0; i < a.length; i++) s += String.fromCharCode(a[i]); try { return decodeURIComponent(escape(s)); } catch { return s; } } });
need("process", { env: {}, platform: "browser", cwd: () => "/", versions: {}, nextTick: (fn, ...a) => Promise.resolve().then(() => fn(...a)) });
need("crypto", { getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 256); return a; }, randomUUID: () => "00000000-0000-4000-8000-000000000000" });
need("AbortController", class { constructor() { this.signal = { aborted: false, addEventListener() {}, removeEventListener() {} }; } abort() { this.signal.aborted = true; } });
need("structuredClone", (v) => JSON.parse(JSON.stringify(v)));
