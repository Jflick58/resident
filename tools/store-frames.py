#!/usr/bin/env python3
"""Makes the App Store images: each screenshot in a drawn device under a headline,
and the product page header and search results images.

    python3 tools/store-frames.py                 everything
    python3 tools/store-frames.py iphone-6.3      one set of screenshots
    python3 tools/store-frames.py creative        the header, search and universal images

The screenshots come from tools/site-shots.sh (the folders under store/screenshots).
Each image is a small HTML page, drawn by headless Chrome at the exact size App Store
Connect takes, into store/screenshots/framed/<set>/ and store/creative/. The headlines
here are the ones in store/listing.md: change them in both places.

Sizes, from Apple's screenshot and creative asset specifications (November 2026):
iPhone 6.3 inch 1206 x 2622 (the required one), 6.9 inch 1320 x 2868, iPad 13 inch
2064 x 2752, iPhone Duo outer 1398 x 2034 and inner 2853 x 2007, product page header
3840 x 1646, search results 3840 x 2560, universal 5244 x 2950.
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

# A sheet on a wide screen is a small card in the middle of it: no use at that size.
SHEETS = {"05-connectors"}

SETS = {
    "iphone-6.3": {
        "shots": "site/assets/img", "size": (1206, 2622), "device": "iPhone",
        "headline": 124, "sub": 50, "top": 174, "gap": 95, "width": 922, "bezel": 20, "radius": 137, "island": True,
    },
    "iphone-6.9": {
        "shots": "store/screenshots/iphone-6.9", "size": (1320, 2868), "device": "iPhone",
        "headline": 136, "sub": 54, "top": 190, "gap": 104, "width": 1010, "bezel": 22, "radius": 150, "island": True,
    },
    "ipad-13": {
        "shots": "store/screenshots/ipad-13", "size": (2064, 2752), "device": "iPad",
        "headline": 150, "sub": 60, "top": 170, "gap": 96, "width": 1500, "bezel": 24, "radius": 84, "skip": SHEETS,
    },
    "duo-outer": {
        "shots": "store/screenshots/duo-outer", "size": (1398, 2034), "device": "iPhone Duo",
        "headline": 118, "sub": 48, "top": 104, "gap": 70, "width": 1010, "bezel": 20, "radius": 120,
    },
    # Open, the phone is held sideways: the headline sits beside the screen.
    "duo-inner": {
        "shots": "store/screenshots/duo-inner", "size": (2853, 2007), "device": "iPhone Duo",
        "headline": 122, "sub": 54, "width": 1480, "bezel": 22, "radius": 88, "beside": True, "skip": SHEETS,
    },
}

STYLE = """
  * {{ box-sizing: border-box; margin: 0; }}
  html, body {{ width: {w}px; height: {h}px; overflow: hidden; }}
  body {{
    background:
      radial-gradient({glow}, rgba(255, 122, 41, 0.30), rgba(244, 81, 108, 0.10) 46%, transparent 72%),
      #0c0c0e;
    color: #f4f3f1;
    font-family: -apple-system, "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
  }}
  h1 {{ font-weight: 700; line-height: 1.04; letter-spacing: -0.035em; }}
  h1 span {{ display: block; white-space: nowrap; }}
  .warm {{
    background: linear-gradient(100deg, #fbc02d, #ff7a29 55%, #f4516c);
    -webkit-background-clip: text; background-clip: text; color: transparent;
    padding-bottom: 0.08em;
  }}
  p {{ line-height: 1.25; color: #b9b8be; letter-spacing: -0.01em; }}
  .device {{
    position: relative; flex: none;
    background: #08080a;
    box-shadow: 0 0 0 3px #55555c, 0 0 0 9px #1c1c20, 0 0 0 12px #3c3c43, 0 90px 180px -60px rgba(0, 0, 0, 0.9);
  }}
  .device img {{ display: block; width: 100%; }}
  .island {{
    position: absolute; left: 50%; transform: translateX(-50%);
    width: 29%; aspect-ratio: 3.35; border-radius: 999px; background: #000;
  }}
"""


def device(source, width, bezel, radius, island=False, extra=""):
    top = round(bezel + (width - 2 * bezel) * 0.031)
    mark = f'<span class="island" style="top:{top}px"></span>' if island else ""
    return (
        f'<div class="device" style="width:{width}px;padding:{bezel}px;border-radius:{radius}px;{extra}">'
        f'<img src="{source.as_uri()}" style="border-radius:{radius - bezel}px">{mark}</div>'
    )


def headline(lines, warm=None):
    return "".join(f'<span{" class=\"warm\"" if index == warm else ""}>{html.escape(line)}</span>' for index, line in enumerate(lines))


def frame_page(spec, file, shot, lines, sub):
    width, height = spec["size"]
    source = ROOT / spec["shots"] / f"shot-{shot}.png"
    title = headline(lines, warm=1 if file == "01-agent" else None)
    under = html.escape(sub.format(device=spec["device"]))
    drawn = device(source, spec["width"], spec["bezel"], spec["radius"], spec.get("island", False))
    if spec.get("beside"):
        style = STYLE.format(w=width, h=height, glow="70% 90% at 0% 30%") + f"""
  body {{ display: flex; align-items: center; gap: 110px; padding: 0 130px; }}
  h1 {{ font-size: {spec["headline"]}px; }}
  p {{ margin-top: {round(spec["sub"] * 0.7)}px; font-size: {spec["sub"]}px; max-width: 16em; }}
  .words {{ flex: 1; min-width: 0; }}
"""
        body = f'<div class="words"><h1>{title}</h1><p>{under}</p></div>{drawn}'
    else:
        style = STYLE.format(w=width, h=height, glow="120% 46% at 50% -6%") + f"""
  body {{ text-align: center; }}
  h1 {{ padding-top: {spec["top"]}px; font-size: {spec["headline"]}px; }}
  p {{ margin-top: {round(spec["sub"] * 0.62)}px; padding: 0 7%; font-size: {spec["sub"]}px; }}
  .device {{ margin: {spec["gap"]}px auto 0; }}
"""
        body = f"<h1>{title}</h1><p>{under}</p>{drawn}"
    return f'<!doctype html><meta charset="utf-8"><style>{style}</style>{body}'


# The product page header, the search results image and the one that can stand for both. Each has
# an "art safe area" that every device shows: the mark and the words stay inside it, and the
# screens beside or under them may be cut off. (width, height, safe x, safe y, safe width, safe height)
CREATIVE = {
    "header": (3840, 1646, 1097, 493, 1646, 661),
    "search": (3840, 2560, 836, 765, 2168, 1030),
    "universal": (5244, 2950, 1921, 660, 1402, 962),
}


def creative_page(name):
    width, height, x, y, safe_w, safe_h = CREATIVE[name]
    shots = ROOT / "store/screenshots/iphone-6.9"
    mark = (ROOT / "site/assets/img/mark.png").as_uri()
    style = STYLE.format(w=width, h=height, glow="90% 80% at 50% 0%")
    if name == "search":
        # The Search tab shows the image's full width and only its top: about 1443 px of it on an
        # iPhone and 1778 px on an iPhone Duo (seen in App Store Connect's preview). So the words
        # go where Apple's safe area and that top band meet, with a screen at each side of them,
        # and nothing that matters sits lower.
        phone, top, band = 660, 130, 1443
        style += f"""
  .safe {{ position: absolute; left: {x}px; top: {y}px; width: {safe_w}px; height: {band - y}px;
          display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; }}
  .safe img {{ height: 150px; }}
  h1 {{ margin-top: 24px; font-size: 186px; }}
  .left, .right {{ position: absolute; top: {top}px; }}
  .left {{ left: 140px; }} .right {{ right: 140px; }}
"""
        body = (
            f'<div class="safe"><img src="{mark}"><h1><span>An AI agent that runs</span><span class="warm">on your device</span></h1></div>'
            f'<div class="left">{device(shots / "shot-chat.png", phone, 16, 100, True)}</div>'
            f'<div class="right">{device(shots / "shot-pull-request.png", phone, 16, 100, True)}</div>'
        )
    else:
        # The mark and the headline in the safe area, a screen at each side.
        scale = safe_h / 661
        size, phone = round(176 * scale), round(safe_w * 0.44)
        side = round((x - phone) / 2)
        top = round(y - safe_h * 0.28)
        style += f"""
  .safe {{ position: absolute; left: {x}px; top: {y}px; width: {safe_w}px; height: {safe_h}px;
          display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; }}
  .safe img {{ height: {round(150 * scale)}px; }}
  h1 {{ margin-top: {round(26 * scale)}px; font-size: {size}px; }}
  .left, .right {{ position: absolute; top: {top}px; }}
  .left {{ left: {side}px; }} .right {{ right: {side}px; }}
"""
        body = (
            f'<div class="safe"><img src="{mark}">{"<h1>" + headline(["Small model.", "Serious agent."], warm=1) + "</h1>"}</div>'
            f'<div class="left">{device(shots / "shot-chat.png", phone, round(phone * 0.022), round(phone * 0.15), True)}</div>'
            f'<div class="right">{device(shots / "shot-pull-request.png", phone, round(phone * 0.022), round(phone * 0.15), True)}</div>'
        )
    return f'<!doctype html><meta charset="utf-8"><style>{style}</style>{body}'


def draw(page, width, height, target, scratch):
    path = pathlib.Path(scratch) / (target.stem + ".html")
    path.write_text(page)
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
         f"--window-size={width},{height}", f"--screenshot={target}", path.as_uri()],
        check=True, capture_output=True)
    size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(target)], capture_output=True, text=True).stdout.split()
    print(f"{target.relative_to(ROOT)}: {size[-3]} x {size[-1]}")


wanted = sys.argv[1:] or [*SETS, "creative"]
with tempfile.TemporaryDirectory() as scratch:
    for name in wanted:
        if name == "creative":
            for asset, (width, height, *_) in CREATIVE.items():
                draw(creative_page(asset), width, height, ROOT / "store" / "creative" / f"{asset}.png", scratch)
            continue
        spec = SETS[name]
        for file, shot, lines, sub in FRAMES:
            if file in spec.get("skip", ()):
                continue
            if not (ROOT / spec["shots"] / f"shot-{shot}.png").exists():
                print(f"{name} {file}: no screenshot")
                continue
            draw(frame_page(spec, file, shot, lines, sub), *spec["size"], ROOT / "store" / "screenshots" / "framed" / name / f"{file}.png", scratch)
