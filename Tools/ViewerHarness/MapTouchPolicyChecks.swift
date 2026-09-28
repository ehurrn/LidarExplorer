//
//  MapTouchPolicyChecks.swift
//  ViewerHarness
//
//  Which touch on the map does what, for each tool (MapTouchPolicy): the owner's navigate-by-default rules of
//  2026-09-28, checked without a device or a Pencil. R4, added with the map bridge (Task 5), reads the bridge's own
//  source for the two things that made the pan lock, and for the guard that keeps a pitched map's sky off the model;
//  R5 checks the rule that guard follows to find the horizon.
//

import Foundation

@MainActor
func runMapTouchPolicyChecks() {
    print("\n=== Map touch policy ===")
    checkTapsAndDrags()
    checkWhatEachRecognizerReceives()
    checkTwoFingerGestures()
    checkMapBridgeSource()
    checkHorizon()
}

@MainActor
private func checkTapsAndDrags() {
    print("\n--- R1. what a tap and a drag do ---")
    let kinds = MapTouchKind.allCases
    func tap(_ tool: MapTool, _ kind: MapTouchKind) -> MapTapAction? { MapTouchPolicy.tap(in: tool, by: kind) }
    func drag(_ tool: MapTool, _ kind: MapTouchKind) -> MapDragAction { MapTouchPolicy.drag(in: tool, by: kind) }

    check("with no tool lit a tap does nothing, finger, Pencil or pointer",
          kinds.allSatisfy { tap(.navigate, $0) == nil })
    check("with no tool lit every one-touch drag pans the map, the Pencil's too",
          kinds.allSatisfy { drag(.navigate, $0) == .panMap })
    check("Spot Inspection: a tap reads the ground, finger or Pencil, and drags still pan",
          kinds.allSatisfy { tap(.spot, $0) == .inspect && drag(.spot, $0) == .panMap })
    check("profile: a tap places a point, finger or Pencil",
          kinds.allSatisfy { tap(.profile, $0) == .placeProfilePoint })
    check("profile: a Pencil drag draws the line; a finger or pointer drag pans",
          drag(.profile, .pencil) == .drawProfile && drag(.profile, .finger) == .panMap && drag(.profile, .pointer) == .panMap)
    check("viewshed: a tap places the observer, and every drag pans (a Pencil drag no longer starts a profile)",
          kinds.allSatisfy { tap(.viewshed, $0) == .placeObserver && drag(.viewshed, $0) == .panMap })
    check("thalweg: every drag traces the channel, and a tap does nothing",
          kinds.allSatisfy { drag(.thalweg, $0) == .drawThalweg && tap(.thalweg, $0) == nil })
    check("split wipe: a tap does nothing and a one-touch drag pans",
          kinds.allSatisfy { tap(.splitWipe, $0) == nil && drag(.splitWipe, $0) == .panMap })
    check("markup's pen and highlighter: the canvas over the map takes every touch",
          kinds.allSatisfy { drag(.markupInk, $0) == .canvas && tap(.markupInk, $0) == nil })
    // A change from e324172, where markup kept the mode explore and the hand tool's tap inspected: a default of the
    // table, not a rule the owner named.
    check("markup's hand tool: every drag pans, the Pencil's too, and a tap does nothing",
          kinds.allSatisfy { drag(.markupHand, $0) == .panMap && tap(.markupHand, $0) == nil })
    // The pan lock, ruled out by construction: no tool but the thalweg's (and the canvas over the map) takes a finger.
    check("one finger pans the map in every tool but the thalweg and markup's canvas",
          MapTool.allCases.allSatisfy { [.thalweg, .markupInk].contains($0) || drag($0, .finger) == .panMap })
    check("a Pencil drag draws only in profile and thalweg",
          MapTool.allCases.filter { [.drawProfile, .drawThalweg].contains(drag($0, .pencil)) } == [.profile, .thalweg])
}

@MainActor
private func checkWhatEachRecognizerReceives() {
    print("\n--- R2. which recognizer receives a touch ---")
    let pairs = MapTool.allCases.flatMap { tool in MapTouchKind.allCases.map { (tool, $0) } }
    check("the draw recognizer receives exactly the touches that draw",
          pairs.allSatisfy { tool, kind in
              MapTouchPolicy.drawRecognizerReceives(in: tool, by: kind)
                  == [.drawProfile, .drawThalweg].contains(MapTouchPolicy.drag(in: tool, by: kind)) })
    check("the tap recognizer receives a touch only where a tap acts",
          pairs.allSatisfy { tool, kind in
              MapTouchPolicy.tapRecognizerReceives(in: tool, by: kind) == (MapTouchPolicy.tap(in: tool, by: kind) != nil) })
    check("the two-finger wipe recognizer receives touches only in the split wipe",
          MapTool.allCases.filter(MapTouchPolicy.wipeRecognizerReceives(in:)) == [.splitWipe])
    check("only a profile tap waits for a double-tap zoom to fail (A and B are never placed at one point by a zoom)",
          MapTool.allCases.filter(MapTouchPolicy.tapWaitsForDoubleTap(in:)) == [.profile])
}

@MainActor
private func checkTwoFingerGestures() {
    print("\n--- R3. two-finger rotate and pitch ---")
    check("rotate and pitch with no tool, Spot Inspection, profile and markup's hand tool",
          [MapTool.navigate, .spot, .profile, .markupHand].allSatisfy(MapTouchPolicy.rotatesAndPitches(in:)))
    check("no rotate or pitch in viewshed, thalweg, the split wipe or under markup's canvas",
          ![MapTool.viewshed, .thalweg, .splitWipe, .markupInk].contains(where: MapTouchPolicy.rotatesAndPitches(in:)))
}

/// The map bridge (not compiled by the harness) read as text, for the two things that made the pan lock: a write to
/// MapKit's scrolling (a Pencil touch turned it off as it landed, and the profile mode kept it off) and a gesture that
/// lights a tool (a Pencil stroke lit the ruler). Also for the guard that keeps a point above a pitched map's horizon
/// from the model (R5 checks where the horizon is), and for the arbitration only a device can exercise.
@MainActor
private func checkMapBridgeSource() {
    print("\n--- R4. the map bridge never switches scrolling or lights a tool, and hands the model no sky ---")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("LidarExplorer/MapLayer/TerrainMapView.swift")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        check("the map bridge's source can be read", false, url.path)
        return
    }
    check("TerrainMapView never writes isScrollEnabled, so no touch can leave one-finger panning off",
          !text.contains("isScrollEnabled"))
    // Cause 2 (a stroke lit the ruler) could come back as a write to any of the tool's state, not only interactionMode,
    // or as a call to one of the model's switches. The thalweg's commit, which ends its own one-shot mode on lift, is
    // the one tool change a gesture makes, and is not a switch here.
    let toolWrite = #"\b(interactionMode|isProfileModeActive|isMarkingUp|markupTool)\s*(=[^=]|\.toggle\()"#
    let toolSwitches = ["toggleSpotInspection", "toggleProfileMode", "toggleViewshedMode", "toggleFieldMarkup",
                        "beginThalwegDrawing", "setSplitWipe"]
    check("TerrainMapView writes none of the tool's state (interactionMode, isProfileModeActive, isMarkingUp, ...)",
          text.range(of: toolWrite, options: .regularExpression) == nil)
    check("TerrainMapView calls none of the model's tool switches: no gesture lights a tool",
          !toolSwitches.contains { text.contains("\($0)(") })
    let modelURL = root.appendingPathComponent("LidarExplorer/Presentation/TerrainViewerModel.swift")
    let modelText = (try? String(contentsOf: modelURL, encoding: .utf8)) ?? ""
    check("the tool switches R4 looks for are still the model's (a rename would blind the check above)",
          toolSwitches.allSatisfy { modelText.contains("public func \($0)(") })
    check("the bridge's recognizers take their touches from MapTouchPolicy",
          ["drawRecognizerReceives", "tapRecognizerReceives", "wipeRecognizerReceives", "rotatesAndPitches",
           "tapWaitsForDoubleTap"].allSatisfy { text.contains("MapTouchPolicy.\($0)") })

    // A pitched map shows sky above its horizon, where MapKit still converts a point to a valid coordinate, far beyond
    // the ground it draws: a tap or a stroke there must read, place and draw nothing. The tap and the draw pan take
    // every point through one guarded helper, `ground(at:on:)`, and never convert directly; it finds the horizon from
    // the ground MapKit draws (`visibleMapRect`), by MapTouchPolicy's rule. (The markup canvas's ink is converted
    // apart, by `markupCoordinateConverter`, and is not held to this.)
    func body(_ signature: String) -> Substring? {
        guard let start = text.range(of: signature) else { return nil }
        let rest = text[start.lowerBound...]
        guard let end = rest.range(of: "\n        }\n") else { return nil }   // the member's closing brace
        return rest[..<end.upperBound]
    }
    check("the bridge's ground(at:on:) drops a point above the horizon (MapTouchPolicy.touchHasGround) or with no "
          + "coordinate", body("func ground(at point: CGPoint").map { ground in
              ground.contains("MapTouchPolicy.touchHasGround(") && ground.contains("CLLocationCoordinate2DIsValid(") } == true)
    check("the bridge finds the horizon from the ground MapKit draws (visibleMapRect), by MapTouchPolicy.horizonRow",
          body("private func horizonRow(on map").map { horizon in
              horizon.contains("MapTouchPolicy.horizonRow(") && horizon.contains("visibleMapRect") } == true)
    check("the tap and the draw pan hand the model only points with ground, through ground(at:on:), not a convert",
          ["func handleTap(", "func handleTransectPan("].allSatisfy { signature in
              body(signature).map { $0.contains("ground(at:") && !$0.contains("toCoordinateFrom") } ?? false })
    check("the thalweg's trace and the profile's line start where the touch landed (the draw pan's landing)",
          body("func handleTransectPan(").map { pan in
              pan.contains("DrawPanGestureRecognizer)?.landing") && pan.contains("extendThalwegDraft(landing)")
                  && pan.contains("beginTransectDrag(at: landing)") } == true)

    // The tap's arbitration, which only the device can exercise: what the tap recognizer yields to, and when a tap it
    // recognised is stale.
    check("a tap on a pin is the pin's only for the reading's pin, the observer and a waypoint (A, B and the location "
          + "dot let the tap through)",
          body("private func isOnOwnPin(").map { pin in
              ["=== spotAnnotation", "=== viewshedAnnotation", "markupAnnotations.contains"].allSatisfy(pin.contains)
                  && !pin.contains("return true") && !pin.contains("is MKAnnotationView") } ?? false)
    check("a tap recognised while a Pencil stroke draws the line does nothing (the stroke's line wins)",
          body("func handleTap(")?.contains("guard !model.isTransectDragging") == true)
    // MapKit's one-finger zoom (a tap, then a drag up or down) is no pan (its class is a UIGestureRecognizer), so the
    // pans' rule missed it: a stroke begun just after a tap could zoom the map under the line, or instead of it.
    check("MapKit's one-finger zoom waits for a stroke the draw pan has taken, as MapKit's pans do",
          body("shouldBeRequiredToFailBy other: UIGestureRecognizer").map { rule in
              rule.contains("is UIPanGestureRecognizer") && rule.contains("OneHandedZoomGestureRecognizer") } == true)
}

/// A pitched map draws sky above its horizon, but MapKit converts a point there to a valid coordinate far beyond the
/// ground it draws (in the Simulator, 75° at 400 m: 729 m out at row 250, the North Pole at row 0), so validity cannot
/// find the horizon. MapKit does report the ground it draws, `visibleMapRect`: the safe area's ground, cut at the far
/// edge. The bridge asks whether both ends of a row lie in it; the numbers below are the Simulator's (iPad Pro 13-inch,
/// portrait: a 1376 pt view, the safe area 32 pt from the top and 20 pt from the bottom, the far edge at row 299.3 at
/// 75° and 159.9 at 70°, and at row 32.25, the safe area's top, on a flat map).
@MainActor
private func checkHorizon() {
    print("\n--- R5. a touch above a pitched map's horizon has no ground ---")
    let safeTop = 32.0, centreRow = 688.0, safeBottom = 1356.0
    func drawn(from edge: Double) -> (Double) -> Bool { { $0 >= edge && $0 <= safeBottom } }
    func horizon(_ rowHasGround: (Double) -> Bool) -> Double? {
        MapTouchPolicy.horizonRow(safeTop: safeTop, centreRow: centreRow, rowHasGround: rowHasGround)
    }

    let at75 = horizon(drawn(from: 299.3))
    check("pitched to show sky, the horizon is the first row whose ends lie in the drawn ground, within half a point",
          at75.map { $0 >= 299.3 && $0 <= 299.8 } == true, "\(String(describing: at75))")
    check("a touch above the horizon has no ground; one on or below it has",
          [0.0, 150, 250, 299].allSatisfy { !MapTouchPolicy.touchHasGround(atRow: $0, horizonRow: at75) }
              && [300.0, 688, 1300].allSatisfy { MapTouchPolicy.touchHasGround(atRow: $0, horizonRow: at75) })
    let at70 = horizon(drawn(from: 159.9))
    check("a lower horizon (70°) is found as well", at70.map { $0 >= 159.9 && $0 <= 160.4 } == true,
          "\(String(describing: at70))")
    // Below the safe area's bottom the drawn rect ends too; the search never asks there, so that strip is never sky.
    check("the strip under the home indicator, outside the drawn rect, keeps its ground",
          MapTouchPolicy.touchHasGround(atRow: 1370, horizonRow: at75))

    let flat = horizon(drawn(from: 32.25))
    check("a flat map shows no sky: the drawn ground reaching the safe area's top is no horizon, and the strip under the "
          + "status bar keeps its ground", flat == nil && MapTouchPolicy.touchHasGround(atRow: 5, horizonRow: flat))
    check("a far edge within two points of the safe area's top is the safe area's, not a horizon",
          horizon(drawn(from: 33.9)) == nil)
    check("a horizon just past that is one", horizon(drawn(from: 40)).map { $0 >= 40 && $0 <= 40.5 } == true)

    // Where MapKit's answer is not the one measured, nothing is dropped: the old behaviour, never a dead tap.
    check("no ground at the centre row (an answer MapKit did not give): nothing is dropped", horizon { _ in false } == nil)
    check("ground in every row, the view's top too: nothing is dropped", horizon { _ in true } == nil)

    var asked: [Double] = []
    _ = horizon { asked.append($0); return drawn(from: 299.3)($0) }
    check("the search asks only rows from the view's top to its centre row, and at most 14 of them",
          asked.allSatisfy { $0 >= 0 && $0 <= centreRow } && asked.count <= 14, "\(asked.count) rows")
}
