# Map Styles Reference — Design

_2026-09-14 · branch `feat/style-guide` · approved by the user in session; revised after the adversarial review in `docs/superpowers/reviews/2026-09-14-map-styles-reference-review.md`_

## Problem

Users trying the micro-topography styles cannot tell what each one shows or
when to use it. The first attempt appended a long "Map Styles" page to the
first-run intro carousel (`VisualPrimerView`). That mixes onboarding with
reference material and hides the map while you read.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Shape | A separate, searchable reference: style list → style detail |
| Example images | None for now (text only) |
| What the top-bar **?** opens | The Map Styles reference; the intro becomes first-launch only, with a **Replay Intro** row in the reference |
| Presentation | Side panel beside the map (`.inspector`) on iPad; sheet on compact widths |

## Behaviour

- **?** toggles the **Map Styles** panel.
  - **Regular width (iPad):** a trailing inspector column,
    `.inspectorColumnWidth(min: 300, ideal: 340, max: 420)`. The map, top bar
    and dock narrow to make room; the map keeps rendering.
  - **Compact width (iPhone, iPad Split View / Slide Over):** a sheet with
    `.medium` and `.large` detents. Background interaction stays at the system
    default (disabled), so no other root sheet can be requested while it is up.
  - Closes with **?** again or the panel's close button.
- **List:** search field; sections **Standard Shading**, **Micro-Topography**
  and **Overlays**. Style rows show the dock chip label and the full name. The
  style currently on the map is marked, and the marker carries
  `accessibilityValue("In use")`. A **Replay Intro** row ends the list.
  Reopening the panel shows the list, scrolled to the style in use.
- **Search:** `localizedStandardContains` against a style's name, chip label,
  *shows*, *reading* and *best for* (not the *Adjust with* text, where
  "Settings" and "slider" appear everywhere). Overlays match on name and
  explanation. An empty query shows everything; no match shows an empty state.
- **Style detail:** full name and chip label, what it shows, *How to read it*,
  *Best for*, *Adjust with* (omitted when empty), and **Use This Style**, which
  sets the map's style and leaves the panel open. It reads **In Use** (disabled)
  when the style is already active, including after a change from the dock.
- **Overlay detail:** name and explanation only.
- **Replay Intro:** presents the two-slide intro from inside the panel's own
  view hierarchy, not from `TerrainViewerView`'s root `.sheet`. On compact
  widths the panel is itself a sheet, and a root sheet request would be dropped.
- **Intro:** `VisualPrimerView` returns to its two original slides; the
  "Map Styles" page and toolbar button added in commit `61a6ee1` are removed.
  First launch still shows it automatically from the root.
- **Top bar with the panel open:** the action buttons take layout priority, and
  the elevation readout is `lineLimit(1)` with tail truncation, so a narrowed
  bar truncates the readout instead of clipping buttons.

## Components

| Unit | Layer | Responsibility |
|---|---|---|
| `ReliefStyleGuide` (exists) | Core | All guide text; **new**: search matching for styles and overlays (fields above) |
| `MapStylesReferenceView` (new) | Presentation | List + detail navigation inside the panel; reads/sets `TerrainViewerModel.style`; hosts the Replay Intro sheet |
| `TerrainViewerView` | Presentation | Owns `showsStyleReference`; attaches the inspector (with column width) to the whole map screen |
| `ViewerTopBarView` | Presentation | **?** toggles the panel (accessibility label "Map Styles"); readout truncates, buttons keep priority |
| `VisualPrimerView` | Presentation | Back to two slides |

Guide content and every decidable rule (search, section membership) stay in
Core, so the harness enforces them.

## Testing

- Harness (`./Tools/run-harness.sh`): keep the four guide checks; add search
  checks — `"rem"` finds Relative Elevation, `"ditch"` includes Local Relief and
  returns only entries whose searched text mentions ditches, `"settings"` does
  not match every style, an empty query returns every style, and a nonsense
  query returns nothing.
- Simulator checklist (screenshots):
  1. iPad Pro 11" **portrait**, panel open, readout showing its longest string: every top-bar button fully visible.
  2. iPad Pro 13": panel beside the map; a detail page; **Use This Style** changes the dock's selected chip and the detail flips to **In Use**.
  3. iPhone 17 Pro: panel as a medium sheet; **Replay Intro** presents the intro.
  4. Elevation style: one panel open/close cycle causes at most one terrain reload (`TileActivityLog`); if more, exclude inspector-driven resizes from the elevation-range refresh.
- `xcodebuild` for device and Simulator with no new warnings in touched files;
  then a run on the user's iPad.

## Out of scope

Example images; per-chip help; localization of guide text; the sun-slider
wiring for Directional Occlusion and Multi-directional (task `task_622c94c2`);
cancelling stranded tile renders on a style switch (follow-up from the review).
