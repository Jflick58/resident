#!/usr/bin/env python3
"""Reads result files written by `harness-spike --suite … --out` and prints the score.

    python3 evals/report.py results.jsonl              one run, by category
    python3 evals/report.py before.jsonl after.jsonl   two runs side by side, and the cases that changed

A file may hold several runs (different models or labels); each is reported apart.
"""
import json
import math
import sys
from collections import defaultdict


def load(path):
    """The runs in a file, keyed by model and label. A case run twice keeps its last result."""
    runs = defaultdict(dict)
    for line in open(path):
        if line.strip():
            row = json.loads(line)
            runs[(row["model"], row.get("label", ""), row.get("thinking", ""))][row["id"]] = row
    return runs


def likely(passed, total):
    """The range the true pass rate is likely in (95%, Wilson)."""
    if not total:
        return 0, 0
    z, p = 1.96, passed / total
    centre = (p + z * z / (2 * total)) / (1 + z * z / total)
    spread = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / (1 + z * z / total)
    return round(max(0, centre - spread) * 100), round(min(1, centre + spread) * 100)


def name(key):
    model, label, thinking = key
    return f"{model}{' [' + label + ']' if label else ''}, thinking {thinking}"


def by_category(rows):
    score = defaultdict(lambda: [0, 0])
    for row in rows.values():
        score[row["category"]][1] += 1
        score[row["category"]][0] += row["pass"]
    return score


def one(key, rows):
    print(f"\n{name(key)}")
    for category, (passed, total) in sorted(by_category(rows).items()):
        print(f"  {category:10} {passed:3}/{total:<3} {passed * 100 // total:3}%")
    passed, total = sum(r["pass"] for r in rows.values()), len(rows)
    low, high = likely(passed, total)
    seconds = sum(r["seconds"] for r in rows.values())
    print(f"  {'total':10} {passed:3}/{total:<3} {passed * 100 // total:3}%  (likely between {low}% and {high}%)  {seconds / total:.1f}s a case")
    for row in sorted(rows.values(), key=lambda r: r["id"]):
        if not row["pass"]:
            print(f"    fail {row['id']}: {row['failure']}")


def two(first, second):
    (key_a, a), (key_b, b) = first, second
    shared = sorted(set(a) & set(b))
    print(f"\nA: {name(key_a)}\nB: {name(key_b)}\n{len(shared)} cases in both")
    score_a = by_category({i: a[i] for i in shared})
    score_b = by_category({i: b[i] for i in shared})
    for category in sorted(score_a):
        (pa, total), (pb, _) = score_a[category], score_b[category]
        print(f"  {category:10} A {pa:3}/{total:<3}  B {pb:3}/{total:<3}  {pb - pa:+d}")
    pa, pb = sum(a[i]["pass"] for i in shared), sum(b[i]["pass"] for i in shared)
    print(f"  {'total':10} A {pa:3}/{len(shared):<3}  B {pb:3}/{len(shared):<3}  {pb - pa:+d}")
    fixed = [i for i in shared if not a[i]["pass"] and b[i]["pass"]]
    broken = [i for i in shared if a[i]["pass"] and not b[i]["pass"]]
    # With the same cases in both runs, only the ones that changed say anything (a sign test).
    changed = len(fixed) + len(broken)
    if changed:
        fewer = min(len(fixed), len(broken))
        chance = min(1.0, 2 * sum(math.comb(changed, k) for k in range(fewer + 1)) / 2**changed)
        print(f"  {len(fixed)} cases pass only in B, {len(broken)} only in A. A split this uneven happens by chance {chance:.0%} of the time.")
    for i in fixed:
        print(f"    now passes  {i}")
    for i in broken:
        print(f"    now fails   {i}: {b[i]['failure']}")


files = sys.argv[1:]
if not files:
    sys.exit(__doc__)
runs = [item for path in files for item in load(path).items()]
if len(runs) == 2:
    two(runs[0], runs[1])
else:
    for key, rows in runs:
        one(key, rows)
