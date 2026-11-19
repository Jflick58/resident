# Resident's website

A small Jekyll site: one page of marketing, plus privacy and support.

    cd site
    jekyll serve        # then open http://localhost:4000

- `index.html` is the page. Its sections are plain HTML; the lists of models
  and questions are in the front matter at the top of the file. The order is
  the argument: what the app is, a recorded run, why it was built, useful
  tasks and agent configuration, the engineering and its evidence, local
  data boundaries, model choice, and how to get it. Technical details,
  including the inference work, expand inside the engineering section.
  That section has a cooler background (`.under`).
- The run under "A real run" is written out by hand from
  `tools/site-chat.json`: each step's time is that message's date less the
  first message's. If the chat is replaced, replace those lines with it, and
  keep the date and execution environment visible. It is a Mac run shown in
  the iPhone simulator, not an on-device timing benchmark. The follow-up
  date calculation is relative to November 16, 2026, not the visitor's date.
- The before-and-after evidence compares the intersection of case IDs in
  `spike-results/suite-lfm3-baseline.jsonl` and `suite-lfm3-after.jsonl`:
  387 shared cases, with 357 and 374 passes respectively. Keep the simulated
  services, fixture repository and run variability explicit when updating it.
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
9:41, and the opening screen is told it is morning to match.

What the page says the app does is what it did when the page was written.
Before publishing, check it against the app. Every number on the page is one
`spike-results/` or the app backs, and the page says where each was measured.
When the app is on the App Store, update the hero, get-started section,
availability FAQ and closing call to action. Make the store link the primary
installation action and retain the source-build instructions for developers.
