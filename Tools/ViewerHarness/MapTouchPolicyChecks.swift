//
//  MapTouchPolicyChecks.swift
//  ViewerHarness
//
//  Which touch on the map does what, for each tool (MapTouchPolicy): the owner's navigate-by-default rules of
//  2026-09-28, checked without a device or a Pencil. R4, added with the map bridge (Task 5), reads the bridge's own
//  source for the two things that made the pan lock, and for the guard that keeps a pitched map's sky off the model.
//

import Foundation

@MainActor
func runMapTouchPolicyChecks() {
    print("\n=== Map touch policy ===")
    checkTapsAndDrags()
    checkWhatEachRecognizerReceives()
    checkTwoFingerGestures()
    checkMapBridgeSource()
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
/// lights a tool (a Pencil stroke lit the ruler). Also for the guard that keeps a point past a pitched map's horizon
/// from the model.
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

    // A pitched map shows sky above its horizon, where MapKit's point-to-coordinate answer is
    // kCLLocationCoordinate2DInvalid (-180, -180): a tap or stroke there must read, place and draw nothing. The tap and
    // the draw pan convert every point through one guarded helper, `ground(at:on:)`, and never convert directly.
    func body(_ signature: String) -> Substring? {
        guard let start = text.range(of: signature) else { return nil }
        let rest = text[start.lowerBound...]
        guard let end = rest.range(of: "\n        }\n") else { return nil }   // the member's closing brace
        return rest[..<end.upperBound]
    }
    check("the bridge's ground(at:on:) drops a point with no ground (CLLocationCoordinate2DIsValid)",
          body("func ground(at point: CGPoint")?.contains("CLLocationCoordinate2DIsValid(") == true)
    check("the tap and the draw pan hand the model only points with ground, through ground(at:on:), not a convert",
          ["func handleTap(", "func handleTransectPan("].allSatisfy { signature in
              body(signature).map { $0.contains("ground(at:") && !$0.contains("toCoordinateFrom") } ?? false })

    // The tap's arbitration, which only the device can exercise: what the tap recognizer yields to, and when a tap it
    // recognised is stale.
    check("a tap on a pin is the pin's only for the reading's pin, the observer and a waypoint (A, B and the location "
          + "dot let the tap through)",
          body("private func isOnOwnPin(").map { pin in
              ["spotAnnotation", "viewshedAnnotation", "markupAnnotations"].allSatisfy(pin.contains)
                  && !pin.contains("is MKAnnotationView") } ?? false)
    check("a tap recognised while a Pencil stroke draws the line does nothing (the stroke's line wins)",
          body("func handleTap(")?.contains("guard !model.isTransectDragging") == true)
}
