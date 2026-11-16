# Resident

*Resident: Fully Local AI Agent.* An iOS app that runs local models on-device
with MLX and gives them a modern agent harness: thinking control, tools, web
search, a code sandbox, connectors, skills and memory, behind a deliberately
small interface.

The idea: with small models the harness matters more than the model. The app is
opinionated about that harness and exposes it as **agents** (instructions, a
switch per tool and connector, thinking, reply length) rather than a wall of
settings.

The app was called Harness while it was being built, and the two packages keep
that name (`HarnessKit`, `HarnessMLX`). The app target, the project and the
bundle ID (`com.jflick.resident`) say Resident.

To build it yourself, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and put in your Apple team ID, a bundle ID of your own
and the name of your phone. That file is not checked in.

## The website

`site/` is a small Jekyll site: one marketing page, plus privacy and support.
`cd site && jekyll serve` runs it (Ruby 3.2.6, set in `site/.ruby-version`).
`tools/site-shots.sh` takes its screenshots from the simulator.

## What is here

| Path | What it is |
|---|---|
| `HarnessKit/` | Swift package with no MLX dependency: agent loop, tools, presets, OpenAI-compatible provider, Hugging Face fit check, model catalog, downloader. 50 tests, run in under a second. |
| `HarnessMLX/` | Swift package: on-device provider on top of MLX Swift LM, plus `harness-spike`, a Mac command-line tool that runs a real model through the harness and scores it. |
| `App/` | SwiftUI app: chat, model library, presets, memory. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, not committed. |
| `run-sim.sh` | Build, install, launch in the booted simulator and take a screenshot. |

## Build and run

```sh
brew install xcodegen          # once
xcodegen generate
open Resident.xcodeproj         # run on a device for on-device models
```

Core tests:

```sh
cd HarnessKit && swift test
```

Real-model check on a Mac (downloads the model to `~/Library/Caches/harness-spike`):

```sh
cd HarnessMLX
xcodebuild -scheme harness-spike -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../DerivedData -skipMacroValidation build
../DerivedData/Build/Products/Debug/harness-spike mlx-community/Qwen3-4B-4bit --thinking low
```

MLX needs a Metal device, so **on-device models do not run in the iOS
simulator**. In the simulator the app offers a scripted demo model and any
server you add (for example Ollama on the same Mac at `http://localhost:11434/v1`).

Debug builds accept launch arguments for scripted runs:
`-openSheet models|chats|settings|presets|hub|presetEditor`, `-hubLink <link>`,
`-addServer "Name|url|model"`, `-demoPrompt "text"`, `-openLatestChat YES`, `-continueTurn YES`.

`run-sim.sh` uses the iPhone Duo simulator (iOS 27.2, Xcode 27.2) unless `SIM`
names another. The Duo has two screens; the script saves the inner one as
`<name>.png` and the outer one as `<name>-outer.png`.

## How the harness works

- **Agent loop** (`Agent.swift`): generate, run requested tools, feed results
  back, up to 8 steps. The last step runs without tools so the model must
  answer. Identical repeated calls are refused, tool results are clipped, and a
  step where the model only thinks and runs out of tokens is retried once with
  thinking off.
- **Context budget**: old tool results are shortened first, then whole old
  turns are dropped. The system prompt and latest user turn always survive.
- **Prompt**: the preset's own instructions, the skills and connectors on
  offer (one line each), the date, then memory. It says nothing about any
  particular tool; each tool's own description says when to use it.
- **Two classes of tool**: the built-in tools (web search, page reader,
  JavaScript, memory, skills) have a switch each, are all on in a new preset,
  and are always declared when on. Everything else is a connector
  (Calendar and Reminders on the device, and any MCP server added), switched
  per preset and opened on demand as described below.
- **Tools**: web search (DuckDuckGo HTML endpoint, on-device, no key), page
  reader (HTML to text, then BM25 passage ranking against the question so a
  long page costs a few hundred tokens), JavaScript (JavaScriptCore, no network
  or files, 5 second limit), memory (one small text file the user can edit).
- **On-device provider** (`MLXEngine.swift`): keeps one `ChatSession` and feeds
  it only messages it has not seen, so each agent step processes new tokens
  rather than the whole transcript. Thinking is switched through the model's
  chat template and capped with a token budget at the Low and Medium levels.
  Tool calls are held to valid syntax by a grammar (`ToolCallGrammar.swift`):
  text and thinking stay free, and once the model opens a tool call only a
  declared tool name and schema-valid arguments can follow.
- **Connectors** (`PersonalTools.swift`, `EventKitSource.swift`): Calendar and
  Reminders, switched on per preset like tools. They read and write the
  device's own calendar and reminders through EventKit, ask for access the
  first time a tool needs it, and take dates the way small models write them
  ("tomorrow 5pm", "friday", `2026-11-15 17:00`).
- **MCP connectors with sign-in** (`HarnessKit/MCP`, `ConnectorsModel.swift`):
  Settings > Connectors adds any MCP server reachable over the web (Streamable
  HTTP), from a short list of suggestions or by address. If the server wants a
  sign-in, the app finds its authorization server (RFC 9728 and RFC 8414, with
  the older fixed paths as a fallback), registers itself (RFC 7591), and runs
  the authorization code flow with PKCE in the system sign-in browser, so the
  app never sees a password. Tokens live in the Keychain and are renewed
  without the user; when renewal fails the connector shows "Sign in needed"
  and the model is told to say so. Services that do not let apps register
  themselves (GitHub) take a client ID, and a secret if they issue one, under
  Advanced. A new connector is switched on in the preset new chats use; each
  preset has a switch per connector and each connector a switch per tool.
  Tool names are prefixed with the connector's name, and results are cut at 6,000 characters so one answer cannot fill a
  small model's context. Tool definitions are trimmed before the model sees
  them (`SchemaTrim`): descriptions to 600 characters and parameter
  descriptions to 120, both at a sentence end where possible; validation
  details, defaults and the insides of nested objects are dropped; lists of
  allowed values stop at 12. Names, types and required parameters are kept. `swift run harness-mcp <url> [--register]` in
  `HarnessKit` checks a server from the command line, and
  `node tools/mock-mcp-server.mjs` is a local server with sign-in to try the
  flow without an account.
- **Connectors opened on demand**: connector tools are never declared up
  front. The model sees one line
  per connector (its purpose and its first ten tool names) and a
  `use_connector` tool. Opening a connector declares its tools if it has 8 or
  fewer, otherwise the 6 that best match what the model said it needs and the
  user's message (keyword ranking, tool names weighted over descriptions); the
  rest are listed by name so it can ask again. Naming a connector in a message
  opens it without a model step. Opened tools stay declared for the rest of
  the chat, at most 12 at once and within a quarter of the context (4,000
  tokens at most), the least recently used dropping out first; one opening
  takes at most three quarters of that. A
  held-back tool called by name is run anyway, and if that call fails the
  error carries the tool's parameters.
- **Gmail and Google Calendar**: Google hosts MCP servers for both
  (`gmailmcp.googleapis.com/mcp/v1`, `calendarmcp.googleapis.com/mcp/v1`), so
  they are suggested connectors, not custom code. Google does not let apps
  register themselves: they need a Google client ID entered under Advanced
  (see `TODO.md`). Gmail has 23 tools costing about 11,000 tokens of
  descriptions, so only search, read-thread and create-draft start switched
  on. Calendars from a Google account added in iOS Settings already appear
  through the built-in Calendar connector with no setup.
- **Skills** (`Skill.swift`, `SkillsView.swift`): instructions for one kind of
  task. The prompt carries one line per skill (name and when to use it); the
  `use_skill` tool loads the steps only when a task matches. Three ship with
  the app (write-email, plan-day, summarize); Settings > Skills edits them,
  adds new ones, and imports a `SKILL.md`.
- **Photos and documents** (`Attachments.swift`, `DocumentReader.swift`): the
  + button attaches photos (library or camera) and files. PDFs are read page
  by page with PDFKit, scanned pages and photos through on-device text
  recognition; text, Markdown, CSV, JSON, code, HTML and RTF are read as text.
  The model gets the first 3,000 characters or so of each document and a
  `read_document` tool to read a page by number or search the rest, so a long
  file does not fill the context. A model that cannot see images gets the
  text found in the photo instead.
- **Memory controls** (`MemoryView`): a switch that turns memory off entirely,
  tap to edit a fact, swipe to remove, Forget Everything. The model can
  correct or remove a fact through `save_memory`'s `forget` argument.
- **Dictation** (`Dictation.swift`): the mic button in the message field
  writes what you say into it. The app runs its own speech model, Parakeet
  (the 220 MB "redux" build, through the FluidAudio package), downloaded on
  first use. Only the microphone permission is asked for. While listening,
  everything heard so far is transcribed again about once a second.
  If Xcode hangs at "Resolve Package Graph" on a fresh checkout, it is stuck
  on a keychain lookup while fetching FluidAudio's binary; run
  `swift package --disable-keychain resolve` in any package that depends on
  FluidAudio once, which fills the shared cache Xcode reads.
- **Rejected tool calls** (`MLXEngine.recover`): the MLX library drops a call
  to a tool it was not told about, or one it cannot parse. The engine hands
  those to the agent as calls that fail with a readable error, so the model
  can correct itself instead of the turn ending empty.
- **Resumable turns** (`ChatModel.continueTurn`): the chat is saved after every
  finished step. A turn cut off by the app closing shows a Continue button;
  one paused by the app going to the background carries on by itself when the
  app returns. Finished tool calls are not repeated.
- **Fit check** (`ModelFit.swift`): from a Hugging Face link, without
  downloading weights, decides format (MLX or not), architecture, memory
  (weights + cache for the context + overhead, against what the device grants
  the app) and storage. Verdicts: runs well, will run with a shorter context,
  too large, or unsupported, each with a one-sentence reason.

## What has been verified

- `HarnessKit`: 84 unit tests pass, including the MCP client and the whole
  sign-in flow (discovery, registration, PKCE, token renewal, a forgotten
  session, answers sent as an event stream) against a stand-in server.
- MCP against real services, from the Mac with `harness-mcp`: tools listed on
  DeepWiki, Hugging Face and Microsoft Learn and a DeepWiki tool called, with
  no sign-in. Linear, Notion, Sentry and Atlassian: sign-in discovery and app
  registration succeed with the app's callback address; the sign-in itself was
  not done, as it needs an account. GitHub offers no registration (client ID
  needed). Stripe refuses the app's callback address.
- MCP in the app, iPhone Duo simulator: DeepWiki added and called from a chat;
  the local sign-in server added through the real sign-in browser, its token
  renewed after expiring, and its tool called from a chat after a relaunch.
  The connector list, detail and add screens were looked at.
- `harness-spike` on an M2 Mac with `mlx-community/Qwen3-4B-4bit`, six tasks
  through the real tools (live DuckDuckGo search and page fetches included):
  6 of 6 with thinking Low, 5 of 6 with thinking Off. Peak memory 2.8 GB.
  `mlx-community/Qwen3-1.7B-4bit` scores 4 of 6; both misses are the model
  answering without calling a tool.
- Connectors opened on demand, `harness-spike --setup open` on an M2 Mac: 17
  tasks, 4 built-in tools plus 13 made-up connectors, all of them small enough
  to open whole. `LiquidAI/LFM3-1.7B-MLX-4bit` passed 17 of 17 with a
  first-step prompt of about 1,200 tokens (4,700 with every tool declared).
  `mlx-community/Qwen3.5-2B-4bit` passed 11 of 17 (9 with every tool
  declared). One run each. Picking 6 tools out of a large connector is covered
  by unit tests only in that run.
- A connector of Linear's size, `harness-spike --setup linear`: Linear's real
  27 tool definitions (`linear-tools.json`, about 13,000 tokens as sent,
  one tool about 2,100) with canned answers, next to the 13 made-up
  connectors; 12 tasks, one run each on an M2 Mac.
  `LiquidAI/LFM3-1.7B-MLX-4bit`: 12 of 12 opened on demand, with or without
  trimming; trimming took the opened tools from up to 5,500 tokens to under
  3,000 and the mean task from 31 to 21 seconds. With all tools declared
  (`--setup linear-all`): 10 of 12, an 18,600-token prompt, 97 seconds a task.
  `mlx-community/Qwen3.5-2B-4bit` opened on demand: 7 of 12 untrimmed, 9 of
  12 trimmed; its misses are mostly searching the web instead of using the
  Linear tools it had been given. Not run against the real Linear server.
- After taking tool guidance out of the system prompt (same tasks, one run
  each): the 17 general tasks were unchanged (LFM3 17, Qwen 3.5 2B 11); on
  the Linear tasks LFM3 stayed at 12 of 12 and Qwen 3.5 2B went from 9 to 10.
- Constrained tool calls: `harness-spike --probe` shows the grammar is enforced
  (the model can only emit the argument the grammar admits; with
  `--no-constrain` it writes its own). On these six tasks it changed no score:
  neither model produced a malformed call, so the failures it prevents did not
  occur. It guards against bad syntax, not against choosing the wrong tool.
- The app builds and runs in the iPhone 17 Pro simulator (iOS 26.5): chat with
  the demo model including a real JavaScript tool run, the model list, the
  Hugging Face link check against live repositories, the preset editor, and a
  chat against a real model served by Ollama.
- On the iPhone Duo simulator (outer screen), with the demo model: a calendar
  question read the simulator's real calendar, a reminder request created a
  real reminder, and a turn cut off after its tool step showed Continue and
  then finished without running the tool again.
- In the Duo simulator with the scripted demo model: a skill loaded from a
  chat; an 11-page PDF attached, with the answer found on page 9 through
  `read_document`; a photo attached to a text-only model, which received the
  text read from it. The Skills and Memory screens were looked at. Google's
  two servers list their tools from the Mac.
- Background downloads (`BackgroundDownloader.swift`): a 1 GB model download
  started in the simulator finished and registered itself as installed after
  the app was terminated.

## Not verified or not built yet

- **Nothing has run on a physical iPhone.** On-device loading, memory limits
  under the increased-memory entitlement, speed and thermals are untested there.
- Vision input is wired through but untested with a real vision model.
- On-device generation pauses when the app goes to the background. iPhones do
  not grant apps GPU time there (`BGTaskScheduler.supportedResources` reports no
  `.gpu` on iPhone per developer reports; iPad may differ). The pause-and-resume
  path is untested on a device: the simulator test covered a turn cut off by
  the app closing, not one paused by backgrounding.
- Split View on the Duo is unseen. The unfolded inner screen was checked (the
  chat sits in a centred column up to 720 points wide); unfolding needs the
  posture buttons in Device Hub, since `simctl` has no fold control.
- Connector tools were exercised by the scripted demo model only, not yet by a
  real model inside the app.
- No sign-in to a real service (Linear, Notion and so on) has been completed,
  and no real model has used an MCP tool inside the app; the scripted demo
  model did. Sign-in was driven with a debug option that skips the system's
  "wants to use … to sign in" prompt; the prompt itself appears as expected.
- Gmail and Google Calendar sign-in is untested: it needs a Google client ID.
  Whether Google accepts this app's sign-in request as built is unknown.
- Dictation: the speech model transcribed a spoken sentence from a sound
  file correctly in the simulator, and the only prompt is the microphone's.
  Live microphone input, the once-a-second updates, and speed and memory on a
  phone are untested.
- The camera, the photo and file pickers, the skill editor and import, and
  editing a memory were built but not operated by hand; attachments were
  driven through a launch option that takes the same code path after picking.
- Word, Pages, Excel and similar files are refused with a hint to export a PDF.
- MCP covers tools only: no resources, prompts, or servers that need a local
  process. Tool schemas go to the model as the server wrote them; a schema the
  constrained-call grammar cannot compile is untested.
- Tool-surface benchmark (`spike-results/results.jsonl`, 17 tasks, one run per
  cell, so a gap of one or two tasks is noise). Tasks passed with all 50 tools
  and full descriptions / one-sentence descriptions / tools attached per
  request / one shell tool: LFM3 1.7B 17/17/16/13, Qwen 3.5 2B 9/9/13/5,
  Qwen 3 1.7B 12/12/8/6, Qwen 3 4B 14/14/14/10. Description length changed
  nothing; the shell was worst everywhere; attaching tools per request helped
  one model and hurt another, and why is not yet looked into. None of the
  per-request or shell setups are in the app.
- A first-class GitHub connector (see `TODO.md`), Python and artifacts are not built.
- Constrained tool calls cover models that write calls as tagged JSON (Qwen,
  Llama). Other formats, such as Gemma's, run unconstrained.
- 1-bit models such as Bonsai are reported as unsupported by the fit check;
  whether the pinned MLX runtime can load them has not been tested.
- `mlx-swift-lm` is pinned to a commit on `main` because the APIs used are
  newer than its latest tag.
- The app has no icon yet and "Harness" is a placeholder name.
