//
//  MapTouchPolicy.swift
//  LidarExplorer
//
//  Which touch on the map does what, for each tool, decided apart from the recognizers that carry it out, so the
//  harness checks the rules no Simulator can reach with a real Pencil (the pattern of HapticRouting.swift).
//
//  The owner's rules (2026-09-28, after the first iPad Pro and Pencil Pro test): with no tool lit, navigating, a tap
//  does nothing and every one-touch drag, finger or Pencil, pans the map. Spot Inspection's tap reads the ground and
//  its drags pan. The profile's tap places A, then B; a Pencil drag draws the line in one stroke; a finger drag pans.
//  Viewshed's tap places the observer. The thalweg's one-touch drag, finger or Pencil, traces the channel (two fingers
//  landing together pan and zoom the map, as MapKit's). The split wipe's two-finger drag moves the wipe. Markup's pen
//  and highlighter canvas covers the map and takes every touch.
//
//  What is absent is the point: the table keeps no state, and no answer in it changes the tool. A Pencil stroke took
//  the map into profile mode, where one-finger scrolling was off, and left it there (the pan lock).
//

import Foundation

/// The tool lit in the top bar (or none), with the two that Settings starts and markup's two kinds of touch.
public nonisolated enum MapTool: String, Sendable, CaseIterable {
    /// No tool lit: the map is for moving around.
    case navigate
    case spot
    case profile
    case viewshed
    case thalweg
    case splitWipe
    /// Markup's pen or highlighter: its drawing canvas lies over the map.
    case markupInk
    /// Markup's hand tool, "Move the map": the canvas is removed.
    case markupHand
}

/// What touched the glass. The map bridge maps `UITouch.TouchType`: `.direct` is a finger, `.pencil` the Pencil,
/// `.indirect` and `.indirectPointer` a pointer (a trackpad or a mouse), which acts as a finger does.
public nonisolated enum MapTouchKind: String, Sendable, CaseIterable {
    case finger, pencil, pointer
}

/// What a tap on the map does.
public nonisolated enum MapTapAction: String, Sendable, CaseIterable {
    case inspect, placeProfilePoint, placeObserver
}

/// What a one-touch drag on the map does. No case changes the tool.
public nonisolated enum MapDragAction: String, Sendable, CaseIterable {
    /// MapKit's own pan takes it.
    case panMap
    /// The app's draw recognizer takes it, and MapKit's pan does not move the map while it draws.
    case drawProfile
    case drawThalweg
    /// Markup's canvas is over the map; the map never sees the touch.
    case canvas
}

public nonisolated enum MapTouchPolicy {

    /// What a tap does, or nil for nothing (the tap recognizer then never receives the touch). Markup's hand tool
    /// moves the map as navigating does, so its tap does nothing, where it used to inspect (markup kept the mode
    /// explore): this table's default, not a rule the owner named, and `case .markupHand: .inspect` brings it back.
    public static func tap(in tool: MapTool, by kind: MapTouchKind) -> MapTapAction? {
        switch tool {
        case .spot: .inspect
        case .profile: .placeProfilePoint
        case .viewshed: .placeObserver
        case .navigate, .thalweg, .splitWipe, .markupInk, .markupHand: nil
        }
    }

    /// What a one-touch drag does.
    public static func drag(in tool: MapTool, by kind: MapTouchKind) -> MapDragAction {
        switch tool {
        case .markupInk: .canvas
        case .profile: kind == .pencil ? .drawProfile : .panMap
        case .thalweg: .drawThalweg
        case .navigate, .spot, .viewshed, .splitWipe, .markupHand: .panMap
        }
    }

    /// Whether the draw recognizer receives this touch: exactly the touches whose drag draws.
    public static func drawRecognizerReceives(in tool: MapTool, by kind: MapTouchKind) -> Bool {
        switch drag(in: tool, by: kind) {
        case .drawProfile, .drawThalweg: true
        case .panMap, .canvas: false
        }
    }

    /// Whether the tap recognizer receives this touch: only where a tap acts, so with no tool lit a tap is not even seen.
    public static func tapRecognizerReceives(in tool: MapTool, by kind: MapTouchKind) -> Bool {
        tap(in: tool, by: kind) != nil
    }

    /// Whether the two-finger wipe recognizer receives touches.
    public static func wipeRecognizerReceives(in tool: MapTool) -> Bool { tool == .splitWipe }

    /// Whether a tap waits for MapKit's double-tap zoom to fail: about a third of a second, 0.36 s from touch-down in
    /// the Simulator against 0.02 s for a tap that does not wait. Only in profile mode, where the two taps of a zoom
    /// would otherwise place A and B at one point; elsewhere a zoom re-reads or re-places at the same spot, which is
    /// harmless, and every tap answers at once.
    public static func tapWaitsForDoubleTap(in tool: MapTool) -> Bool { tool == .profile }

    /// Whether two fingers rotate and pitch the map: wherever one finger pans and no tool uses two fingers, except
    /// viewshed, which keeps them off as it always has (a default, not a rule the owner named).
    public static func rotatesAndPitches(in tool: MapTool) -> Bool {
        switch tool {
        case .navigate, .spot, .profile, .markupHand: true
        case .viewshed, .thalweg, .splitWipe, .markupInk: false
        }
    }
}
