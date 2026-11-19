# Evals

423 cases that put a model through Resident's harness on a Mac and check what it did. They exist to answer two questions with more than a handful of examples: how good is this model inside the harness, and did a change to the harness help or hurt.

Everything outside the model is faked, so a run depends on the model and the harness and nothing else:

- **Connectors** are 11 stand-ins in `HarnessMLX/Sources/harness-spike/Connectors.swift` (calendar, reminders, contacts, notes, mail, health, weather, maps, music, timers, home), and GitHub's and Linear's real tool definitions with canned answers (`GitHub.swift`, `Linear.swift`). They are opened on demand, as in the app.
- **Files** are the app's own file tools on a real folder, emptied before each case. A case can say which files are in it to begin with. Cloning a repository and opening a pull request go to a made-up GitHub that holds one repository, `acme/rocket`.
- **The web** is `web.json`: invented search results and pages. The facts in it are made up, so a model cannot answer from memory, and a run needs no network.
- **Skills** are the app's built-in ones plus one a model wrote on a phone.

## Running it

Build `harness-spike` once (see the main README), then from the repository root:

```sh
SPIKE=DerivedData/Build/Products/Debug/harness-spike

# The whole suite. About two hours for a 2B model on an M-series Mac.
$SPIKE LiquidAI/LFM3-1.7B-MLX-4bit --thinking low --suite all --out results.jsonl

# About 60 cases, the same ones every time, every category in proportion.
$SPIKE LiquidAI/LFM3-1.7B-MLX-4bit --thinking low --suite all --sample 60 --out results.jsonl

# Some categories only.
$SPIKE LiquidAI/LFM3-1.7B-MLX-4bit --suite all --category linear,followup --out results.jsonl
```

| Option | What it does |
|---|---|
| `--suite all` | Run the cases in `evals/cases`. A folder or one `.jsonl` file works too. |
| `--sample N` | About N cases, chosen the same way each time. `--seed S` picks a different set. |
| `--category a,b` | Only these categories. |
| `--ids a,b` | Only the cases whose id starts with one of these. |
| `--out file` | Append one line per case to this file as it finishes. |
| `--resume` | Skip cases the `--out` file already has for this model and label. |
| `--label name` | Name the run, to tell two runs of one model apart. |
| `--apple` | Use Apple's on-device model in place of an MLX one. |

`python3 evals/report.py results.jsonl` prints the score by category. Given two result files, it puts them side by side and lists the cases that changed.

## Comparing two versions of the harness

Run the same cases before and after, with a label each:

```sh
$SPIKE LiquidAI/LFM3-1.7B-MLX-4bit --suite all --label before --out before.jsonl
# make the change, rebuild
$SPIKE LiquidAI/LFM3-1.7B-MLX-4bit --suite all --label after --out after.jsonl
python3 evals/report.py before.jsonl after.jsonl
```

A model does not give the same answer twice, so a few cases flip between any two runs. The report says how likely the split it saw is by chance. Treat a difference as real only when that is small.

## Comparing builds of one model

A model is published in several builds: the weights as trained, and the same weights rounded to fewer bits in more than one way. The suite is a poor way to choose between them. Most builds pass most cases, and a model does not answer the same way twice, so two builds a few cases apart may be the same. What the rounding changed can be measured directly instead:

```sh
# Keep the prompts of a run: every request the agent sent to the model.
HARNESS_RECORD_REQUESTS=requests.jsonl $SPIKE LiquidAI/LFM3-1.7B-MLX-4bit --thinking low --suite all --sample 70 --out run.jsonl

# Put them to the weights as trained, then to each build. The first model named is the reference.
$SPIKE --fidelity requests.jsonl LiquidAI/LFM3-1.7B-MLX-bf16 \
    LiquidAI/LFM3-1.7B-MLX-4bit LiquidAI/LFM3-1.7B-MLX-6bit --limit 48 --samples reference.plist --discard
```

The reference is given each prompt and writes the start of its reply, always taking its likeliest token. Each build is then walked down the same reply and asked, at every token, what it would have written there. One line comes out per build:

| Column | What it says |
|---|---|
| divergence | How far the build's view of the next token is from the reference's, averaged over every token (the Kullback-Leibler divergence, in nats). Nothing lost is 0. |
| worst in twenty | The same for the token in twenty where the build was furthest off. |
| same token | How often the build's likeliest token is the reference's. |
| same reply | How often the build would have written the whole start of the reply token for token. |

| Option | What it does |
|---|---|
| `--limit N` | Compare about N of the recorded prompts, spread over the file. 48 by default takes a 2B model about five minutes a build. |
| `--reply-tokens N` | How much of each reply to compare. 96 by default. |
| `--samples file` | Keep the reference's replies in this file, so a later run with other builds does not write them again. |
| `--discard` | Delete each build this run had to download once it is scored. The reference stays. |

The first line is the reference against itself and must read 0 and 100%: if it does not, the comparison is at fault and not a build. The reference has to fit in the Mac's memory; for a model too large for that, its 8-bit build is the nearest thing. Run it with nothing else using the graphics processor, or macOS may stop one of the two.

It compares builds of one model. A model retrained to be small, as the Bonsai models are, is a different model from the one it came from: put those through the suite.

## Replaying a chat on a real repository

The pull request cases work on a made-up repository of six files. A real one is where a small model gets lost, so a chat can be put to a model against a folder standing in for a repository:

```sh
git -C ~/code/project archive HEAD | tar -x -C /tmp/project
$SPIKE LiquidAI/LFM3-1.7B-MLX-6bit --thinking low \
    --chat "What repo is your code at|Can you open a PR to change the accent color to green" \
    --repository-folder /tmp/project --repository owner/project --save chat.json
```

The chat has GitHub and the file tools as the app has them, with the app's own limits and sampling. Cloning that repository copies the folder, and a pull request is printed as the lines it changes and sent nowhere. `--save` keeps the chat the way the app keeps it, with what the model thought at each step, which is where to look when a run goes wrong. This is how a chat that failed on a phone is reproduced: copy it off the phone, read where it went wrong, and replay its messages here until the harness gets the model through.

The same chat can be run for real. With `--live` in place of the folder, cloning downloads the repository from GitHub and the pull request is opened on it, through the code the app uses (`GitHubHost`), with a token in `GITHUB_TOKEN`:

```sh
GITHUB_TOKEN=$(gh auth token) $SPIKE LiquidAI/LFM3-1.7B-MLX-6bit --thinking low \
    --chat "File search in owner/project stops at 30 matches. Open a PR that raises it to 40." \
    --repository owner/project --live --live-paths Sources/Search.swift --save chat.json
```

Such a run is held to that one repository and to one pull request, and with `--live-paths` a pull request that changes any other file is refused before anything is sent. GitHub's own connector still answers from canned data here, so a run in which the model calls one of its tools is not a real one. The pull request shown on the website was made this way: `spike-results/pullrequest-live.txt` is that run and the practice runs before it, and `tools/site-pull-request.json` is its chat.

## The categories

| Category | Cases | What it checks |
|---|---|---|
| `direct` | 43 | Answers without reaching for a tool when none is needed. |
| `calc` | 36 | Arithmetic and dates, with the code tool for the hard ones. |
| `memory` | 17 | Saves lasting facts, uses the ones it has, ignores passing remarks. |
| `lookup` | 91 | Finds the right tool in the right connector, reads the answer, changes nothing. |
| `action` | 54 | Changes something with the right arguments: times, dates, ids, names. |
| `multi` | 29 | Several tools in order, carrying a result from one to the next. |
| `linear` | 40 | A connector of real size, with Linear's own tool definitions. |
| `followup` | 26 | A second message that only makes sense after the first. |
| `skills` | 10 | Loads a skill when a task matches, and not otherwise. |
| `web` | 20 | Searches, reads pages, and says so when there is nothing to find. |
| `honesty` | 21 | Does not invent what it could not find, asks when it lacks what it needs, and ignores orders hidden in a web page. |
| `pullrequest` | 23 | Opens a pull request on a repository: clones it, finds the file, changes only what was asked, and never merges. Three cases have the user's own files in the folder already, or add a file at the top of the repository. |
| `files` | 13 | Works on the user's own files: writes, lists, finds, reads and changes them, and leaves GitHub out of it. |

## Writing cases

Cases are written in `build.py` and generated into `cases/*.jsonl`. Edit `build.py`, then run `python3 evals/build.py`. Most requests are worded several ways, because a harness that works for one wording only does not work.

```python
add("lookup", "con-phone",
    ["What's Maria Lopez's phone number?", "I need Maria Lopez's number."],
    readonly=True, tools=["contacts_search"], answer=["555-0142"])
```

| Check | Passes when |
|---|---|
| `tools` | Every one of these tools ran. |
| `anyTool` | At least one of these ran. |
| `noTools` | No tool ran. |
| `forbid` | None of these ran. `readonly=True` forbids every tool that changes something. |
| `lastTurnNoTools` | No tool ran in the last turn of a chat. |
| `args` | Each text is in the arguments of some call. |
| `argsAny` | One of the texts is. |
| `answer` | Each text is in the final answer. |
| `answerAny` | One of the texts is. |
| `answerNot` | None of the texts is. |

Text is compared in lower case with thousands commas removed. A wording that is a list is a chat of several turns. `memory="…"` gives the assistant facts it already remembers, and `files={"notes/trip.md": "…"}` puts files in the files folder before the chat starts.

A check must match what the fake world returns, so read the tool's handler before writing one. A case the best model fails for a reason that is not its fault is noise: fix the case or the world.
