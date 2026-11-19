# Resident's website

A small Jekyll site: one page of marketing, plus privacy and support.

    cd site
    jekyll serve        # then open http://localhost:4000

- `index.html` is the page. Its sections are plain HTML; the lists of models
  and questions are in the front matter at the top of the file. The order is
  the argument: what the app is, its use cases as screenshots of real chats,
  what it can do, why a local model matters, why it was built, the
  engineering (what goes wrong with a small model and what the harness does
  about it, then the inference work), and the models. The two engineering
  sections have a cooler background (`.under`).
- The use cases under "See it work" are shown as screenshots of the app, not
  as drawings of it. The tool-call counts beside them come from the saved
  chats, `tools/site-chat.json` and `tools/site-pull-request.json`. Those
  chats were run on a Mac, so the page gives no timings for them: a time shown
  there would have to say where it was measured. If a chat is replaced, take
  the screenshots again and correct the counts.
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
When the app is on the App Store, replace the two "Coming soon to the App
Store" lines (under the first buttons and at the foot) with the link, and make
it the first button.
