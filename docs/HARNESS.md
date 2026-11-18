# How the harness works

The detail behind the [README](../README.md): what each part of the harness
does, with the file to read for it. The app was called Harness while it was
being built, and the two packages keep that name (`HarnessKit`, `HarnessMLX`).


- **Agent loop** (`Agent.swift`): generate, run requested tools, feed results
  back, up to 8 steps. On the last step the model is told it has no calls left;
  the tools stay declared so the start of the prompt does not change, and are
  taken away only if it calls one anyway. Identical repeated calls are refused,
  tool results are clipped, and a step where the model only thinks and runs out
  of tokens is retried once with thinking off.
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
  A model whose weights fill the device's memory thinks only when it is
  switched on in the chat: on a 12 GB phone a 27B's replies with thinking fell
  from 6 tokens a second to 2 over 400 tokens, and without it came at 7.
  Tool calls are held to valid syntax by a grammar (`ToolCallGrammar.swift`):
  text and thinking stay free, and once the model opens a tool call only a
  declared tool name and schema-valid arguments can follow.
- **Connectors** (`PersonalTools.swift`, `EventKitSource.swift`): Calendar and
  Reminders, switched on per preset like tools. They read and write the
  device's own calendar and reminders through EventKit, ask for access the
  first time a tool needs it, and take dates the way small models write them
  ("tomorrow 5pm", "friday", `2026-11-15 17:00`).
- **Files** (`HarnessKit/Code`): a third connector on the device, with the
  five tools a coding agent has and the names it gives them: `list_files`,
  `search_files`, `read_file`, `edit_file`, `write_file`. They work on one
  folder (`Workspace`) and know nothing of where a file came from. The folder
  is the app's Documents folder, which the Files app shows as Resident under
  On My iPhone: what the user puts there the tools can work on, and what a
  model writes the user can take out. Nothing but files goes in it, and a
  cloned repository there is left out of the device's backups.
  Small models tuned for code have seen that loop endlessly, so an edit
  is the text to find and the text that replaces it, never the whole file
  written back; a long file is read a part at a time; a search prints
  `path:line: text`; a path that is nearly right gets "did you mean".
- **GitHub at the two ends** (`RepositoryCopy.swift`, `RepositoryHost.swift`):
  with the GitHub connector signed in, Files gains two tools and no more.
  `repo_clone` downloads a repository into a folder of its own, named
  after it, beside whatever else is in the files folder, and
  `repo_open_pull_request` sends back the files changed there: the branch, the
  commit and the upload are the harness's business, and the model only says
  what the pull request is called. Everything between is the file tools. A
  file of the repository may be named with its folder (`rocket/web/styles.css`,
  as the tools print it) or from inside it (`web/styles.css`, as the user says
  it). One repository is kept at a time. While these two are there, GitHub's
  connector comes without its own tools for changing code (make a branch, write
  a file back whole, create a pull request): they cannot see what was changed
  on the device, and with both ways in front of it a model left for them after
  its edit in 6 pull request tasks of 23. A call to one of their names, or to
  one a model makes up (`github_open_pull_request`), is answered with the tool
  that does the job. Given GitHub's own tools alone, Bonsai 9B finished 7 of
  13 pull request tasks; this way LFM3 1.7B finishes 23 of 23.
- **MCP connectors with sign-in** (`HarnessKit/MCP`, `ConnectorsModel.swift`):
  Settings > Connectors adds any MCP server reachable over the web (Streamable
  HTTP), from a short list of suggestions or by address. If the server wants a
  sign-in, the app finds its authorization server (RFC 9728 and RFC 8414, with
  the older fixed paths as a fallback), registers itself (RFC 7591), and runs
  the authorization code flow with PKCE in the system sign-in browser, so the
  app never sees a password. Tokens live in the Keychain and are renewed
  without the user; when renewal fails the connector shows "Sign in needed"
  and the model is told to say so. GitHub does not let apps register
  themselves, so it signs in with a short code typed at github.com (the device
  flow, RFC 8628), which needs a client ID and no secret; the ID is built in
  from `Config/Local.xcconfig` or entered under Advanced. A new connector is switched on in the preset new chats use; each
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
  opens it without a model step, and the service's own usage notes go into the prompt. Opened tools stay declared for the rest of
  the chat, at most 12 at once and within a quarter of the context (4,000
  tokens at most), the least recently used dropping out first; one opening
  takes at most three quarters of that. A
  held-back tool called by name is run anyway, and if that call fails the
  error carries the tool's parameters.
- **Gmail and Google Calendar**: Google hosts MCP servers for both, but they
  answer only projects enrolled in its Workspace developer preview, so the two
  are defined in `ConnectorsView.swift` and left off the suggested list.
  Calendars from a Google account added in iOS Settings already appear through
  the built-in Calendar connector with no setup.
- **Skills** (`Skill.swift`, `SkillsView.swift`): instructions for one kind of
  task. The prompt carries one line per skill (name and when to use it); the
  `use_skill` tool loads the steps only when a task matches. Four ship with
  the app (write-email, plan-day, summarize, open-pull-request); Settings > Skills edits them,
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
