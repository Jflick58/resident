# Evals

388 cases that put a model through Resident's harness on a Mac and check what it did. They exist to answer two questions with more than a handful of examples: how good is this model inside the harness, and did a change to the harness help or hurt.

Everything outside the model is faked, so a run depends on the model and the harness and nothing else:

- **Connectors** are the 13 stand-ins in `HarnessMLX/Sources/harness-spike/Connectors.swift` (calendar, reminders, contacts, notes, GitHub, mail, health, weather, maps, files, music, timers, home) and Linear's real 27 tool definitions with canned answers (`Linear.swift`). They are opened on demand, as in the app.
- **The web** is `web.json`: invented search results and pages. The facts in it are made up, so a model cannot answer from memory, and a run needs no network.
- **Skills** are the app's three built-in ones plus one a model wrote on a phone.

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

## The categories

| Category | Cases | What it checks |
|---|---|---|
| `direct` | 43 | Answers without reaching for a tool when none is needed. |
| `calc` | 36 | Arithmetic and dates, with the code tool for the hard ones. |
| `memory` | 17 | Saves lasting facts, uses the ones it has, ignores passing remarks. |
| `lookup` | 92 | Finds the right tool in the right connector, reads the answer, changes nothing. |
| `action` | 54 | Changes something with the right arguments: times, dates, ids, names. |
| `multi` | 29 | Several tools in order, carrying a result from one to the next. |
| `linear` | 40 | A connector of real size, with Linear's own tool definitions. |
| `followup` | 26 | A second message that only makes sense after the first. |
| `skills` | 10 | Loads a skill when a task matches, and not otherwise. |
| `web` | 20 | Searches, reads pages, and says so when there is nothing to find. |
| `honesty` | 21 | Does not invent what it could not find, asks when it lacks what it needs, and ignores orders hidden in a web page. |

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

Text is compared in lower case with thousands commas removed. A wording that is a list is a chat of several turns. `memory="…"` gives the assistant facts it already remembers.

A check must match what the fake world returns, so read the tool's handler before writing one. A case the best model fails for a reason that is not its fault is noise: fix the case or the world.
