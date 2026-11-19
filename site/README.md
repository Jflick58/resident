# Resident's website

A small Jekyll site: one page of marketing, plus privacy and support.

    cd site
    jekyll serve        # then open http://localhost:4000

- `index.html` is the page. Its sections are plain HTML; the lists of models
  and questions are in the front matter at the top of the file. The page goes
  down like an iceberg: why a local model matters, then three depths under the
  surface (the harness, the engineering that keeps a small model dependable,
  and the inference work). The iceberg is an SVG drawn in the page, and each
  deeper section has a slightly deeper background (`.deep-1` to `.deep-3`).
- `assets/css/style.css` holds every style. Colours are variables at the top,
  taken from the app's mark, with a dark and a light set.
- `assets/img/` holds the mark, the icon and the screenshots. The screenshots
  come from the simulator (`./run-sim.sh`), never from a real phone, so they
  hold nobody's data.

The screenshots come from `tools/site-shots.sh`, taken in the iPhone 18 Pro
simulator: the opening screen, a chat, the models, the agents, Settings and
the services that can be connected. The simulator cannot run a model, so the
chat shown is one LFM3 1.7B really had: it was run on a Mac through the same
agent, saved to `tools/site-chat.json`, and put in the simulator's data with
LFM3 listed as the model on the device. To show a different chat, save a new
one (the script says how) and run the script again. The status bar is set to
9:41, and the opening screen is told it is morning to match. The shortcut and
Live Activity panel is drawn in HTML and is not a screenshot.

What the page says the app does is what it did when the page was written.
Before publishing, check it against the app, and replace the "coming soon"
button with the App Store link.
