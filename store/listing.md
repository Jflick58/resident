# App Store listing

What goes in each field of App Store Connect for version 1.0. Apple searches the name, the
subtitle and the keyword field, and not the description, so the words people type are spread
over those three with none repeated.

## Name (30 characters, 30 used)

    Resident: Fully Local AI Agent

## Subtitle (30 characters, 29 used)

    Private offline LLM assistant

A second choice, if that reads too plain: `On-device LLM with real tools` (29).

## Keywords (100 characters, 99 used)

    chatbot,chat,device,mlx,mcp,coding,shortcuts,automation,model,open,source,research,web,search,tools

No word here is in the name or the subtitle: Apple already counts those, and a repeat wastes
room. No other product's name is here either (no model, app or company names), which Apple
rejects in this field. Single words only, because Apple joins them itself: "open" and "source"
cover "open source", "web" and "search" cover "web search".

## Promotional text (170 characters, 167 used; can change without a new build)

    An AI agent that runs on your iPhone. It researches on the web, works on your files and code, and uses the services you connect, with a model that stays on the device.

## Description

    Resident is an AI agent that runs on your iPhone and iPad. The model is on the device, so it works offline and your conversations are not sent to a model provider.

    It does more than chat. Give it a task and it uses tools across several steps to carry it out.

    WHAT IT CAN DO
    • Research: searches the web, reads the pages and answers from what it found.
    • Files and code: lists, searches, reads and edits files in a folder you can see in the Files app.
    • Pull requests: with GitHub connected, it clones a repository, changes the code and opens a pull request for you to review.
    • Code sandbox: runs JavaScript on the device, so sums, dates and data are worked out and not guessed.
    • Your day: reads your calendar and reminders and adds to them, through iOS itself.
    • Connectors: GitHub, Linear, Notion, Atlassian, Sentry and Hugging Face, or any MCP server by its address. You sign in on the service's own page.
    • Skills: saved instructions for one kind of job, loaded when a request needs them. Import a SKILL.md or save one from a chat.
    • Memory: a short list of facts about you that you can read, edit or switch off.
    • Shortcuts: the Ask Resident action puts an agent in your automations, with the app closed.

    BUILT FOR SMALL MODELS
    A small model needs help to do real work. Resident shows it only the tools a request needs, corrects a bad tool call so it can try again, and keeps what it has already read so each step is quick.

    MODELS
    Start with LFM3 1.7B, or pick from the Qwen, Gemma and Bonsai models in the library. Add any MLX model from Hugging Face by its link. Resident checks that a model fits your device before it downloads. On a device with Apple Intelligence you can use the built-in model with nothing to download. You can also point Resident at a model server you run yourself.

    PRIVATE BY DESIGN
    No account. No analytics. Resident has no server. What you write leaves the device only when a tool you switched on sends it: a web search, a page request, or a call to a service you connected.

    GOOD TO KNOW
    • Models are downloaded separately. The recommended one is about 1.3 GB.
    • Larger models need a recent device with more memory.
    • The Shortcuts action needs iOS 27. The built-in model needs a device with Apple Intelligence.
    • Small models make mistakes. Check their answers and their changes.

    Resident is open source under the Apache 2.0 license.

## What's New in This Version

    The first release.

## The rest of the page

| Field | Value |
|---|---|
| Primary category | Productivity |
| Secondary category | Developer Tools |
| Price | Free |
| Support URL | https://getresident.app/support/ |
| Marketing URL | https://getresident.app/ |
| Privacy Policy URL | https://getresident.app/privacy/ |
| App Privacy | Data Not Collected |
| Age rating | Answer "yes" to unrestricted web access: the agent reads web pages. Expect a high rating for it |
| Copyright | 2026 and your name, as you want it shown |

## Notes for App Review

    Resident runs language models on the device. No account or sign-in is needed to use it.

    To test:
    1. Open the app, tap the model name at the top and download "LFM3 1.7B" (about 1.3 GB, over Wi-Fi). On a device with Apple Intelligence you can pick "Apple Intelligence" and skip the download.
    2. Ask: "What's the latest stable version of Swift?" The agent searches the web, reads pages and answers. Its steps appear in the chat.
    3. Ask: "How many days until New Year's Day?" It runs a short JavaScript calculation.

    Models are weights only, downloaded from Hugging Face. They contain no executable code. The code tool runs JavaScript in JavaScriptCore with no network and no file access.

    Connectors (Settings > Connectors) are optional. Each is a sign-in to the user's own account at a third-party service such as GitHub or Linear, on that service's own page. The app works without any.

    The "Ask Resident" Shortcuts action needs iOS 27. Models larger than the recommended one need a device with more memory, and the app says which fit before a download.

## Screenshots

The images are in `store/screenshots/framed/`, made by `tools/store-frames.py` from the
screenshots beside them. Upload them in this order. The first three are the ones shown in
search results.

| # | Headline | Line under it | Screenshot |
|---|---|---|---|
| 1 | Small model. Serious agent. | A private AI agent that runs on your iPhone | The opening screen |
| 2 | It researches for you | Searches the web, reads the pages, answers | A question researched on the web |
| 3 | From request to pull request | Finds the code, changes it, opens the PR | The end of a chat that opened a pull request |
| 4 | Works it out in code | A sandbox on the device for sums, dates and data | A date worked out by running code |
| 5 | Connect the tools you use | GitHub, Linear, Notion and any MCP server | Add Connector (iPhone only) |
| 6 | The newest small models | LFM3, Qwen, Gemma, Bonsai, or any MLX model | The model library |
| 7 | Agents, skills and memory | Shape how it works and what it remembers | Settings |
| 8 | An agent on a schedule | Ask Resident runs in Shortcuts, app closed | Not made yet: needs a screenshot of the action in Shortcuts, from a phone |
