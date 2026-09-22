# Place Search — Design

_2026-09-21 · approved by the user in chat_

## Problem

The top bar has a "my location" button (GPS) and an "Explore LiDAR Sites" button (a fixed catalog of curated
earthwork/crater/volcano sites plus the user's own bookmarks). Neither lets someone type an arbitrary place — a city
name or a zip code — and go there. Today the only way to reach anywhere else is to drag and pinch the map by hand.

## What this adds

One more top-bar button, a magnifying glass, the same 36×36 style as the others. Tapping it opens a small search
panel that floats over the map, just under the top bar — not a full sheet. It holds a text field and, as the user
types, a short list of live suggestions from MapKit (city, state / zip). Tapping a suggestion flies the map there and
closes the panel. Tapping the magnifying glass again while it's open closes it and clears whatever was typed.

## Data flow

1. Tap the button → the panel appears, empty.
2. Typing updates the query. Each change is handed to `MKLocalSearchCompleter` (via `updateQuery(_:near:)`, passing
   the model's current `visibleRegion` every time so the bias tracks if the map moved), which does its own network
   calls and debouncing — nothing in this app needs to re-implement that. Biasing to the viewport means that of
   several places sharing a name, the one nearest what's on screen ranks first — the same instinct as Apple Maps. The
   completer's `resultTypes` is set to addresses/places rather than points of interest, so "Springfield" surfaces the
   towns, not a dentist's office of the same name — matching "city name or zip code," not a business search.
3. The completer's delegate callback delivers a list of suggestions (title + subtitle only — MapKit doesn't hand back
   a coordinate at this stage). They render as rows under the field.
4. Tapping a suggestion resolves it: `MKLocalSearch(request: MKLocalSearchRequest(completion:))` returns map items;
   the first one's coordinate and the response's `boundingRegion` become where the map flies. That region goes
   through the same clamping the model already applies to a GeoTIFF's footprint (`flyTo(footprint:)`: longitude
   wrapped into ±180, latitude clamped to ±85, both spans floored and capped) — a resolved place can be a single
   address (nearly a point) or an entire city; the existing clamp already handles both without new logic. The panel
   closes and the query clears.
5. If resolving fails, or the completer errors out, or there are no results: reuse the model's existing
   `statusMessage` text (the same mechanism "Location unavailable" already uses) with something like "Couldn't find
   that place." The panel stays open so the user can try again or edit the query.

## Where the code goes

Following the pattern already in the app for the location button (`LocationProviding` / `LocationService`, in
`Presentation/`): a small protocol whose interface uses only plain types (`CLLocationCoordinate2D`, the existing
`GeoRegion`), so the parts of the model that use it stay testable on the host, plus a real implementation that only
Xcode/the Simulator exercises, because it talks to Apple's servers and can't be driven deterministically in the
harness.

- `Presentation/PlaceSearchProviding.swift` — new file.
  - `PlaceSuggestion` (`Identifiable`, `Sendable`): `id`, `title`, `subtitle` — enough to render a row.
  - `ResolvedPlace` (`Sendable`): `coordinate: CLLocationCoordinate2D`, `region: GeoRegion`, `name: String`.
  - `PlaceSearchProviding` (`@MainActor` protocol, mirrors `LocationProviding`):
    - `var onSuggestionsUpdate: (([PlaceSuggestion]) -> Void)? { get set }`
    - `func updateQuery(_ text: String, near region: MKCoordinateRegion)` — empty text clears suggestions without a
      network call.
    - `func resolve(_ suggestion: PlaceSuggestion) async -> ResolvedPlace?`
- `Presentation/PlaceSearchService.swift` — new file. `final class PlaceSearchService: NSObject, PlaceSearchProviding,
  MKLocalSearchCompleterDelegate` (delegate conformance is why it's an `NSObject`, exactly like `LocationService`).
  Imports `MapKit`; no `UIKit`, so — like `LocationService` — it still compiles on the host and can go in the
  harness's compile list (proves it builds; it is not functionally exercised there).
- `Presentation/TerrainViewerModel.swift` — a new `// MARK: - Place Search` section next to the existing Location and
  Landmarks ones (not a separate extension file: this needs no UIKit, so there's no reason to split it out the way
  `TerrainViewerModel+OfflineHarvest.swift` had to be). Adds:
  - `placeSearch: any PlaceSearchProviding` (injected in `init`, defaulting to `PlaceSearchService()`, matching how
    `location` is injected).
  - `public var isSearchingPlace = false`
  - `public var placeSearchQuery = ""` — its setter (or a `didSet`) calls `placeSearch.updateQuery(_:near:)`.
  - `public private(set) var placeSuggestions: [PlaceSuggestion] = []` — set from `onSuggestionsUpdate`, wired in
    `start()` next to `location.onUpdate`.
  - `public func selectPlaceSuggestion(_ suggestion: PlaceSuggestion) async` — resolves it, flies there through the
    existing `flyTo(footprint:)`, clears `placeSearchQuery`/`placeSuggestions`, sets `isSearchingPlace = false`; on a
    `nil` result, sets `statusMessage` instead and leaves the panel open.
  - `public func togglePlaceSearch()` — flips `isSearchingPlace`; closing also clears the query and suggestions.
- `Presentation/ViewerTopBarView.swift` — one more `Button` in `actionButtons`, icon `magnifyingglass`, calling
  `model.togglePlaceSearch()`.
- `Presentation/PlaceSearchBarView.swift` — new small view: the field + suggestion rows, shown by
  `TerrainViewerView.swift` in the map's `ZStack` under the top bar while `model.isSearchingPlace` is true.

## Testing

`Tools/ViewerHarness/PlaceSearchChecks.swift` (new), with a fake `PlaceSearchProviding` (records `updateQuery` calls,
lets the check push canned suggestions through `onSuggestionsUpdate`, and returns a scripted `ResolvedPlace?` from
`resolve`), covering:

- Typing forwards the query to the provider and the suggestions it publishes reach `model.placeSuggestions`; an empty
  query clears suggestions without a call reaching `resolve`.
- Picking a suggestion flies to the resolved region through the same clamp `flyTo(footprint:)` already applies —
  worth the same style of hostile-input cases already used for the GeoTIFF-import flyTo (a region crossing the
  antimeridian, a near-zero span, a centre near a pole) — and clears the query and suggestions, and closes the panel.
- A `resolve` that returns `nil` sets `statusMessage` and leaves the panel open with the query intact.
- `togglePlaceSearch()` opens and closes the panel; closing while suggestions are showing clears them.

`PlaceSearchService.swift` is added to `Tools/run-harness.sh`'s compile list so it builds on the host, the same
treatment `LocationService.swift` gets, with no functional check against it (no deterministic way to script Apple's
live search results).

iOS Simulator, by hand: the button appears and fits in the top bar; tapping it opens the panel; typing a real city or
zip shows suggestions; tapping one flies the map and closes the panel; the recommended empty-state and error wording
read reasonably.

## Non-goals

No bookmarking of search results, no search history, no merging with the existing "Explore LiDAR Sites" sheet.

## Open risk

The top bar already holds 7 buttons and the elevation readout truncates at 11" portrait width. This adds an 8th.
Verify in the Simulator that it still fits; if it doesn't, the fallback is the readout's existing truncation
behaviour absorbing the difference, same as it does today — no design change anticipated, just something to confirm
once built rather than guess at now.
