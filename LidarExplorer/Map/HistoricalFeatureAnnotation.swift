//
//  HistoricalFeatureAnnotation.swift
//  LidarExplorer
//
//  Map annotations for historical features
//

import MapKit
import SwiftUI

// MARK: - Historical Feature Annotation

class HistoricalFeatureAnnotation: NSObject, MKAnnotation {
    let feature: HistoricalFeature

    var coordinate: CLLocationCoordinate2D {
        feature.coordinate
    }

    var title: String? {
        feature.title
    }

    var subtitle: String? {
        feature.subtitle
    }

    init(feature: HistoricalFeature) {
        self.feature = feature
        super.init()
    }
}

// MARK: - Custom Annotation View

class HistoricalFeatureAnnotationView: MKMarkerAnnotationView {
    override var annotation: MKAnnotation? {
        willSet {
            guard let featureAnnotation = newValue as? HistoricalFeatureAnnotation else { return }
            let feature = featureAnnotation.feature

            // Set marker color based on confidence
            switch feature.confidence {
            case .confirmed:
                markerTintColor = .systemGreen
            case .veryHigh:
                markerTintColor = .systemBlue
            case .high:
                markerTintColor = .systemTeal
            case .medium:
                markerTintColor = .systemYellow
            case .low:
                markerTintColor = .systemOrange
            case .veryLow:
                markerTintColor = .systemRed
            }

            // Set icon based on feature type
            glyphImage = UIImage(systemName: feature.featureType.icon)

            // Enable callout
            canShowCallout = true

            // Add detail button
            let detailButton = UIButton(type: .detailDisclosure)
            rightCalloutAccessoryView = detailButton

            // Add image if available (placeholder for now)
            let imageView = UIImageView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
            imageView.contentMode = .scaleAspectFill
            imageView.layer.cornerRadius = 5
            imageView.clipsToBounds = true

            // Use feature type icon as placeholder
            imageView.image = UIImage(systemName: feature.featureType.icon)?.withTintColor(.white, renderingMode: .alwaysOriginal)
            imageView.backgroundColor = markerTintColor?.withAlphaComponent(0.3)

            leftCalloutAccessoryView = imageView

            // Set display priority
            displayPriority = feature.confidence == .confirmed ?
                .required : .defaultHigh
        }
    }
}

// MARK: - Feature Cluster Annotation Configuration

extension MKClusterAnnotation {
    /// Configures the cluster annotation with appropriate title and subtitle based on member features
    func configureForHistoricalFeatures() {
        guard !memberAnnotations.isEmpty else {
            title = "Historical Features"
            subtitle = nil
            return
        }
        
        title = "\(memberAnnotations.count) Features"
        
        // Update subtitle based on feature types
        let featureAnnotations = memberAnnotations.compactMap { $0 as? HistoricalFeatureAnnotation }
        
        guard !featureAnnotations.isEmpty else {
            subtitle = nil
            return
        }
        
        let featureTypes = featureAnnotations.map { $0.feature.featureType }
        let uniqueTypes = Set(featureTypes)
        
        if uniqueTypes.count == 1 {
            subtitle = featureTypes.first?.rawValue ?? ""
        } else {
            subtitle = "Mixed Types"
        }
    }
}

// MARK: - Feature Circle Overlay (for highlighting areas)

class HistoricalFeatureCircle: MKCircle {
    let feature: HistoricalFeature

    init(feature: HistoricalFeature, radius: CLLocationDistance = 50) {
        self.feature = feature
        super.init(center: feature.coordinate, radius: radius)
    }
}

// MARK: - Feature Circle Renderer

class HistoricalFeatureCircleRenderer: MKCircleRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let circle = overlay as? HistoricalFeatureCircle else { return }

        let feature = circle.feature

        // Set color based on confidence
        var color: UIColor
        switch feature.confidence {
        case .confirmed:
            color = .systemGreen
        case .veryHigh:
            color = .systemBlue
        case .high:
            color = .systemTeal
        case .medium:
            color = .systemYellow
        case .low:
            color = .systemOrange
        case .veryLow:
            color = .systemRed
        }

        fillColor = color.withAlphaComponent(0.3)
        strokeColor = color.withAlphaComponent(0.8)
        lineWidth = 2.0

        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

// MARK: - Feature Detection Overlay Renderer

class FeatureDetectionOverlayRenderer: MKOverlayRenderer {
    private let features: [HistoricalFeature]
    private let highlightColor: UIColor
    private let highlightOpacity: CGFloat

    init(overlay: MKOverlay, features: [HistoricalFeature], color: UIColor = .yellow, opacity: CGFloat = 0.6) {
        self.features = features
        self.highlightColor = color
        self.highlightOpacity = opacity
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.setFillColor(highlightColor.withAlphaComponent(highlightOpacity).cgColor)
        context.setStrokeColor(highlightColor.cgColor)
        context.setLineWidth(2.0 / zoomScale)

        for feature in features {
            let point = MKMapPoint(feature.coordinate)
            let radius = (feature.area ?? 100.0) / 2.0 // Convert area to radius
            let radiusInMapPoints = radius * MKMapPointsPerMeterAtLatitude(feature.coordinate.latitude)

            _ = CGRect(
                x: CGFloat(point.x - radiusInMapPoints),
                y: CGFloat(point.y - radiusInMapPoints),
                width: CGFloat(radiusInMapPoints * 2),
                height: CGFloat(radiusInMapPoints * 2)
            )

            let screenRect = self.rect(for: MKMapRect(
                origin: MKMapPoint(x: point.x - radiusInMapPoints, y: point.y - radiusInMapPoints),
                size: MKMapSize(width: radiusInMapPoints * 2, height: radiusInMapPoints * 2)
            ))

            context.fillEllipse(in: screenRect)
            context.strokeEllipse(in: screenRect)
        }
    }
}
