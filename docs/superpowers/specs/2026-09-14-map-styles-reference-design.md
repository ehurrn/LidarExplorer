# Map Styles Reference — Design

_2026-09-14 · branch `feat/style-guide` · approved by the user in session_

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
| Presentation | Side panel beside the map (`.inspector`) on iPad; half-height, draggable sheet on iPhone |

## Behaviour

- **?** toggles the **Map Styles** panel. On iPad (regular width) it opens on
  the trailing edge and the map, top bar and dock narrow to make room; the map
  keeps rendering. On compact width it presents as a sheet at medium height,
  draggable to large. It closes with **?** again or its close button.
- **List:** search field; sections **Standard Shading**, **Micro-Topography**
  and **Overlays**. Style rows show the dock chip label and the full name; the
  style currently on the map is marked. A **Replay Intro** row ends the list.
- **Search:** case- and diacritic-insensitive match against a style's name,
  chip label, and guide text (shows / reading / best for / controls). Overlays
  match on name and explanation. An empty query shows everything; no match
  shows an empty state.
- **Style detail:** full name and chip label, what it shows, *How to read it*,
  *Best for*, *Adjust with* (omitted when empty), and **Use This Style**, which
  sets the map's style and leaves the panel open. It reads **In Use** (disabled)
  when the style is already active.
- **Overlay detail:** name and explanation only.
- **Replay Intro** presents the two-slide intro sheet.
- **Intro:** `VisualPrimerView` returns to its two original slides; the
  "Map Styles" page and toolbar button added in commit `61a6ee1` are removed.
  First launch still shows it automatically.

## Components

| Unit | Layer | Responsibility |
|---|---|---|
| `ReliefStyleGuide` (exists) | Core | All guide text; **new**: search matching for styles and overlays |
| `MapStylesReferenceView` (new) | Presentation | List + detail navigation inside the panel; reads/sets `TerrainViewerModel.style`; calls back for Replay Intro |
| `TerrainViewerView` | Presentation | Owns `showsStyleReference`; attaches the inspector to the whole map screen |
| `ViewerTopBarView` | Presentation | **?** toggles the panel; accessibility label "Map Styles" |
| `VisualPrimerView` | Presentation | Back to two slides |

Guide content stays in Core so the harness keeps enforcing that every
`ReliefStyle` has a complete entry.

## Testing

- Harness (`./Tools/run-harness.sh`): keep the four guide checks; add search
  checks — `"rem"` finds Relative Elevation, `"ditch"` returns only entries
  whose text mentions ditches and includes Local Relief, an empty query
  returns every style, and a nonsense query returns nothing.
- Simulator screenshots: iPad Pro 13" with the panel beside the map, a detail
  page, and **Use This Style** changing the dock's selected chip; iPhone 17 Pro
  with the medium-height sheet.
- `xcodebuild` for device and Simulator with no new warnings in touched files;
  then a run on the user's iPad.

## Out of scope

Example images; per-chip help; the sun-slider wiring for Directional Occlusion
and Multi-directional (separate task `task_622c94c2`).
