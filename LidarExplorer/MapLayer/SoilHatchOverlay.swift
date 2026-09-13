//
//  SoilHatchOverlay.swift
//  LidarExplorer
//
//  SSURGO classes drawn as hatching: hydric clays diagonal blue, sandy levees cross-hatched tan.
//

import CoreGraphics
import MapKit
#if canImport(UIKit)
import UIKit
#endif

public nonisolated final class SoilMultiPolygon: MKMultiPolygon, @unchecked Sendable {
    public var soilClass: SoilClass = .other
}

public enum SoilOverlayFactory {
    /// One multipolygon per mapped class; `.other` is not drawn.
    public static func overlays(from survey: SoilSurvey) -> [SoilMultiPolygon] {
        var grouped: [SoilClass: [MKPolygon]] = [:]
        for polygon in survey.polygons where polygon.unit.soilClass != .other {
            for part in polygon.parts {
                guard let exterior = part.first else { continue }
                let holes = part.dropFirst().map { ring in
                    MKPolygon(coordinates: ring.map { CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x) }, count: ring.count)
                }
                let shape = MKPolygon(coordinates: exterior.map { CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x) },
                                      count: exterior.count, interiorPolygons: Array(holes))
                grouped[polygon.unit.soilClass, default: []].append(shape)
            }
        }
        return grouped.map { soilClass, polygons in
            let multi = SoilMultiPolygon(polygons)
            multi.soilClass = soilClass
            return multi
        }
    }
}

public nonisolated final class SoilHatchRenderer: MKMultiPolygonRenderer {
    public override func fillPath(_ path: CGPath, in context: CGContext) {
        let soilClass = (overlay as? SoilMultiPolygon)?.soilClass ?? .other
        let crosshatch = soilClass == .wellDrainedSandyLoam
        let color = crosshatch ? CGColor(red: 0.78, green: 0.58, blue: 0.28, alpha: 0.85) : CGColor(red: 0.16, green: 0.42, blue: 0.86, alpha: 0.85)
        context.saveGState()
        context.addPath(path)
        context.clip(using: .evenOdd)
        let bounds = path.boundingBoxOfPath
        let spacing = abs(context.convertToUserSpace(CGSize(width: 9, height: 9)).width)
        context.setStrokeColor(color)
        context.setLineWidth(abs(context.convertToUserSpace(CGSize(width: 1.2, height: 1.2)).width))
        var offset = -bounds.height
        while offset < bounds.width + bounds.height {
            context.move(to: CGPoint(x: bounds.minX + offset, y: bounds.minY))
            context.addLine(to: CGPoint(x: bounds.minX + offset + bounds.height, y: bounds.maxY))
            if crosshatch {
                context.move(to: CGPoint(x: bounds.minX + offset + bounds.height, y: bounds.minY))
                context.addLine(to: CGPoint(x: bounds.minX + offset, y: bounds.maxY))
            }
            offset += spacing * (crosshatch ? 1.6 : 1)
        }
        context.strokePath()
        context.restoreGState()
    }
}
