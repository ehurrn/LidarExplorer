//
//  MapTouchPolicyChecks.swift
//  ViewerHarness
//
//  Which touch on the map does what, for each tool (MapTouchPolicy): the owner's navigate-by-default rules of
//  2026-09-28, checked without a device or a Pencil. R4, added with the map bridge (Task 5), reads the bridge's own
//  source for the two things that made the pan lock.
//

import Foundation

@MainActor
func runMapTouchPolicyChecks() {
    print("\n=== Map touch policy ===")
    checkTapsAndDrags()
    checkWhatEachRecognizerReceives()
    checkTwoFingerGestures()
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
