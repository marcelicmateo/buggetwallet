# Engineer direction: mockups (2026-11-02)

The owner picked this direction on 2026-11-02 ("lets go in this direction"). The spec and the handoff are in
`docs/context/ENG_UI_SPEC.md`; this folder only holds the mockup sources.

- Live canvas (private): https://claude.ai/artifact/HEyzibzxFzy4cnHFQfrCFf. The page **Engineer** has the picked
  screens (dark row, light row), **Structure (v1)** has the site map and the flows the engineer screens build on,
  and **Fun directions** has the three rejected styles (kept for reference only).
- `screens/`: the five engineer screens, dark and `-Light`. `structure/`: the v1 screens. That's where the
  navigation, the "Needs you" queue, Add, the Money timeline, Payment, Bill, Plan, Saving, Settings and first run
  come from. Restyle them with the engineer tokens; their layout and copy still hold.
- The files are canvas artboards (`.dc.html`: HTML plus a small `Component` class). Outside the canvas they don't
  render (`./support.js` is the canvas runtime), so read them as source. The `renderVals()` of each file holds the
  example math: the house planner, the sparkline scaling, the heatmap levels.
- **Every number in them is synthetic.** None of them is a real figure from the owner.
