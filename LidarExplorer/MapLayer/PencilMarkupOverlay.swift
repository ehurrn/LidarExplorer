//
//  PencilMarkupOverlay.swift
//  LidarExplorer
//
//  The drawing layer over the map. A `PKCanvasView` takes Apple Pencil strokes (and finger strokes, unless the system's
//  "Only Draw with Apple Pencil" is on); when a stroke ends it
//  is handed to the viewer model, which places it on the ground through the map's own coordinate conversion, and
//  the canvas is wiped. What stays on screen is then the map's own polyline for that trace, so it moves and
//  scales with the terrain instead of floating over it.
//

#if canImport(UIKit) && canImport(PencilKit)
import PencilKit
import SwiftUI
import UIKit

public struct PencilMarkupCanvas: UIViewRepresentable {

    let model: TerrainViewerModel

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = Self.drawingPolicy
        // The ink as it will be saved. PencilKit takes an ink colour as its light-appearance colour and, in dark mode,
        // draws the dark variant (white ink drew near-black), while the saved trace is the map's polyline in the colour
        // itself (UIColor(traceHex:), the same in either appearance): so white drew black and turned white on lift.
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        canvas.tool = Self.tool(for: model)
        return canvas
    }

    public func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = Self.tool(for: model)
        // Read again at each update: a change made in Settings while the layer is up takes hold at the next pick of a
        // tool or a colour, or when the layer next comes up (it is rebuilt when markup comes on, or a drawing tool is picked
        // after the hand).
        let policy = Self.drawingPolicy
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
    }

    /// What draws on the layer. On a device, as the system's "Only Draw with Apple Pencil" setting says: with it on, a
    /// finger laid on the map (a habitual pan) draws nothing, where `.anyInput` saved it as a trace. Not `.default`, which
    /// honours the setting only while PencilKit's own tool picker is on screen and otherwise accepts the Pencil alone
    /// (Apple's `PKCanvasViewDrawingPolicy.default`): this layer has its own toolbar, and an iPhone, which has no
    /// Pencil, could then draw nothing. In the Simulator, any input: its touches are fingers.
    private static var drawingPolicy: PKCanvasViewDrawingPolicy {
        #if targetEnvironment(simulator)
        return .anyInput
        #else
        return UIPencilInteraction.prefersPencilOnlyDrawing ? .pencilOnly : .anyInput
        #endif
    }

    public func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    /// The ink the model's selection calls for.
    private static func tool(for model: TerrainViewerModel) -> PKInkingTool {
        let color = UIColor(markupHex: model.markupColorHex) ?? .systemRed
        switch model.markupTool {
        case .highlighter:
            return PKInkingTool(.marker, color: color, width: model.markupInkWidth)
        case .pen, .hand:
            return PKInkingTool(.pen, color: color, width: model.markupInkWidth)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let model: TerrainViewerModel
        /// True while this coordinator is clearing the canvas, whose own change notification must be ignored.
        private var isClearing = false

        init(model: TerrainViewerModel) {
            self.model = model
        }

        public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isClearing, !canvasView.drawing.strokes.isEmpty else { return }
            for stroke in canvasView.drawing.strokes {
                // Window coordinates: the map converts from its own window, so the canvas and the map need not
                // share a frame or an origin.
                let points = stroke.path.interpolatedPoints(by: .distance(3)).map {
                    canvasView.convert($0.location, to: nil)
                }
                model.addFieldTrace(
                    screenPoints: Array(points), colorHex: model.markupInkHex, strokeWidth: model.markupInkWidth)
            }
            isClearing = true
            canvasView.drawing = PKDrawing()
            isClearing = false
        }
    }
}

extension UIColor {
    /// `#RRGGBB`, with or without a leading `#`.
    convenience init?(markupHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// The colour a saved trace was drawn in: `#RRGGBB` or `#RRGGBBAA`.
    convenience init?(traceHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}
#endif
