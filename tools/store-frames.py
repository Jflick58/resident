#!/usr/bin/env python3
"""Makes the App Store images: each screenshot in a drawn device under a headline.

    python3 tools/store-frames.py            every frame, iPhone and iPad
    python3 tools/store-frames.py iphone     one set

The screenshots come from tools/site-shots.sh (store/screenshots/iphone-6.9 and ipad-13).
Each frame is a small HTML page, drawn by headless Chrome at the exact size App Store
Connect takes, into store/screenshots/framed/<set>/. The headlines here are the ones in
store/listing.md: change them in both places.
"""
import html
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# (file, screenshot, headline lines, the line under it)
FRAMES = [
    ("01-agent", "home", ["Small model.", "Serious agent."], "A private AI agent that runs on your {device}"),
    ("02-research", "chat", ["It researches", "for you"], "Searches the web, reads the pages, answers"),
    ("03-pull-request", "pull-request", ["From request", "to pull request"], "Finds the code, changes it, opens the PR"),
    ("04-code", "code", ["Works it out", "in code"], "A sandbox on the device for sums, dates and data"),
    ("05-connectors", "connectors", ["Connect the", "tools you use"], "GitHub, Linear, Notion and any MCP server"),
    ("06-models", "models", ["The newest", "small models"], "LFM3, Qwen, Gemma, Bonsai, or any MLX model"),
    ("07-agents", "settings", ["Agents, skills", "and memory"], "Shape how it works and what it remembers"),
]

SETS = {
    "iphone": {
        "shots": "store/screenshots/iphone-6.9", "size": (1320, 2868), "device": "iPhone",
        "headline": 136, "sub": 54, "top": 190, "gap": 104, "width": 1010, "bezel": 22, "radius": 150, "island": True,
        "skip": set(),
    },
    "ipad": {
        "shots": "store/screenshots/ipad-13", "size": (2064, 2752), "device": "iPad",
        "headline": 150, "sub": 60, "top": 170, "gap": 96, "width": 1500, "bezel": 24, "radius": 84, "island": False,
        # A sheet on an iPad is a small card in the middle of the screen: no use at this size.
        "skip": {"05-connectors"},
    },
}

PAGE = """<!doctype html>
<meta charset="utf-8">
<style>
  * {{ box-sizing: border-box; margin: 0; }}
  html, body {{ width: {w}px; height: {h}px; overflow: hidden; }}
  body {{
    background:
      radial-gradient(120% 46% at 50% -6%, rgba(255, 122, 41, 0.30), rgba(244, 81, 108, 0.10) 46%, transparent 72%),
      #0c0c0e;
    color: #f4f3f1;
    font-family: -apple-system, "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
    text-align: center;
  }}
  h1 {{
    padding-top: {top}px;
    font-size: {headline}px;
    font-weight: 700;
    line-height: 1.04;
    letter-spacing: -0.035em;
  }}
  h1 span {{ display: block; }}
  h1 .warm {{
    background: linear-gradient(100deg, #fbc02d, #ff7a29 55%, #f4516c);
    -webkit-background-clip: text; background-clip: text; color: transparent;
    padding-bottom: 0.08em;
  }}
  p {{ margin-top: {subgap}px; padding: 0 7%; font-size: {sub}px; line-height: 1.25; color: #b9b8be; letter-spacing: -0.01em; }}
  .device {{
    position: relative;
    width: {width}px;
    margin: {gap}px auto 0;
    padding: {bezel}px;
    border-radius: {radius}px;
    background: #08080a;
    box-shadow: 0 0 0 3px #55555c, 0 0 0 9px #1c1c20, 0 0 0 12px #3c3c43, 0 90px 180px -60px rgba(0, 0, 0, 0.9);
  }}
  .device img {{ display: block; width: 100%; border-radius: {inner}px; }}
  .island {{
    position: absolute; top: {islandtop}px; left: 50%; transform: translateX(-50%);
    width: 29%; aspect-ratio: 3.35; border-radius: 999px; background: #000;
  }}
</style>
<h1>{lines}</h1>
<p>{sub_text}</p>
<div class="device"><img src="{shot}">{island}</div>
"""


def render(name, spec, out):
    width, height = spec["size"]
    out.mkdir(parents=True, exist_ok=True)
    made = []
    with tempfile.TemporaryDirectory() as scratch:
        for file, shot, lines, sub in FRAMES:
            if file in spec["skip"]:
                continue
            source = ROOT / spec["shots"] / f"shot-{shot}.png"
            if not source.exists():
                print(f"{name} {file}: no {source.relative_to(ROOT)}")
                continue
            spans = "".join(
                f'<span{" class=\"warm\"" if file == "01-agent" and index == 1 else ""}>{html.escape(line)}</span>'
                for index, line in enumerate(lines)
            )
            page = PAGE.format(
                w=width, h=height, top=spec["top"], headline=spec["headline"], sub=spec["sub"],
                subgap=round(spec["sub"] * 0.62), gap=spec["gap"], width=spec["width"], bezel=spec["bezel"],
                radius=spec["radius"], inner=spec["radius"] - spec["bezel"],
                islandtop=round(spec["bezel"] + (spec["width"] - 2 * spec["bezel"]) * 0.031),
                lines=spans, sub_text=html.escape(sub.format(device=spec["device"])), shot=source.as_uri(),
                island='<span class="island"></span>' if spec["island"] else "",
            )
            path = pathlib.Path(scratch) / f"{file}.html"
            path.write_text(page)
            target = out / f"{file}.png"
            subprocess.run(
                [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                 f"--window-size={width},{height}", f"--screenshot={target}", path.as_uri()],
                check=True, capture_output=True)
            made.append(target)
    for target in made:
        size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(target)], capture_output=True, text=True).stdout.split()
        print(f"{target.relative_to(ROOT)}: {size[-3]} x {size[-1]}")


wanted = sys.argv[1:] or list(SETS)
for name in wanted:
    render(name, SETS[name], ROOT / "store" / "screenshots" / "framed" / name)
