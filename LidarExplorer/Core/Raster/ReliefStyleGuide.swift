//
//  ReliefStyleGuide.swift
//  LidarExplorer
//
//  Plain-language explanations of every map style, for the in-app guide.
//

import Foundation

/// What one map style shows, how to read it, and when to reach for it.
public nonisolated struct ReliefStyleGuideEntry: Sendable, Equatable {
    /// What the style computes, in one or two sentences.
    public let shows: String
    /// How its colours or tones map to the ground.
    public let reading: String
    /// The features and questions it is best at.
    public let bestFor: String
    /// Controls that change it, named as they appear in the app.
    public let controls: [String]
}

/// The guide's content, grouped the way the dock presents the styles.
///
/// Lives beside ``ReliefStyle`` rather than in the view so the harness can
/// hold it to covering every style: a style added to the dock without an
/// explanation fails the build's checks instead of shipping unexplained.
public nonisolated enum ReliefStyleGuide {

    public nonisolated struct Section: Sendable, Identifiable {
        public let title: String
        public let subtitle: String
        public let styles: [ReliefStyle]
        public let isMicroTopography: Bool
        public var id: String { title }
    }

    /// A layer drawn over the map style, switched on in Settings.
    public nonisolated struct Overlay: Sendable, Identifiable {
        public let name: String
        public let explanation: String
        public var id: String { name }
    }

    public static let sections: [Section] = [
        Section(
            title: "Standard Shading",
            subtitle: "Quick to draw at every zoom level. Good for getting oriented before you zoom in.",
            styles: ReliefStyle.allCases.filter { $0.microTopographyProduct == nil },
            isMicroTopography: false
        ),
        Section(
            title: "Micro-Topography",
            subtitle: "Analysis views built from 1 m USGS 3DEP lidar. Zoom in to street level, where the lidar is sharpest; each one brings out a different kind of subtle feature.",
            styles: ReliefStyle.allCases.filter { $0.microTopographyProduct != nil },
            isMicroTopography: true
        ),
    ]

    public static let overlays: [Overlay] = [
        Overlay(
            name: "Contour Lines",
            explanation: "Lines of equal height at the interval you pick, with every fifth line drawn bolder (every tenth at 0.25 m). Close lines mean steep ground. Works on every style."
        ),
        Overlay(
            name: "Habitation Potential Mask",
            explanation: "Paints amber over nearly flat ground (4° or less) that lies within 30 m of a steep slope (25° or more): benches, terraces and bluff-edge spurs where people often lived or built. (Micro-topography styles only.)"
        ),
        Overlay(
            name: "Sky-View Shading",
            explanation: "Darkens enclosed places (ditches, hollows, the foot of banks) on top of whichever micro-topography style you are using, for extra depth. Drag toward 0 to turn it off."
        ),
    ]
}

public extension ReliefStyle {

    /// The short name shown on this style's chip in the dock.
    var dockLabel: String {
        switch self {
        case .multiDirectional: "Multi-Dir"
        case .hillshade: "Hillshade"
        case .slope: "Slope"
        case .elevation: "Elevation"
        case .topographicOpenness: "Openness"
        case .rrim: "RRIM"
        case .localRelief: "LRM"
        case .skyView: "SVF"
        case .rakingLight: "Raking"
        case .relativeElevation: "REM"
        case .curvature: "Curv"
        case .directionalOcclusion: "Occ"
        case .positiveOpenness: "PosOp"
        case .negativeOpenness: "NegOp"
        case .vectorRuggedness: "VRM"
        case .differenceOfGaussians: "DoG"
        }
    }

    /// This style's entry in the in-app guide.
    var guide: ReliefStyleGuideEntry {
        switch self {
        case .hillshade:
            ReliefStyleGuideEntry(
                shows: "The ground lit by a single sun, like a shaded relief map.",
                reading: "Slopes facing the sun are bright and slopes facing away are dark. Features running parallel to the light cast no shadow and can disappear.",
                bestFor: "A natural-looking overview: recognising hills, valleys, terraces and river banks.",
                controls: ["Sun direction slider (dock)", "Sun Altitude (Settings)"]
            )
        case .multiDirectional:
            ReliefStyleGuideEntry(
                shows: "Shading from four light directions at once, drawn as a soft shadow layer over the basemap.",
                reading: "Darker on steeper slopes, edges, banks and breaks of slope, without directional bias. Flat ground stays clear.",
                bestFor: "Seeing features at every orientation without chasing the sun. A good everyday default.",
                controls: ["Sun Altitude (Settings)"]
            )
        case .slope:
            ReliefStyleGuideEntry(
                shows: "How steep the ground is, from flat to 45° and steeper.",
                reading: "Blue is flat, pale is gentle, orange is steep and dark red is 45° or more.",
                bestFor: "Finding flat platforms and terraces, and steep banks, scarps and gully sides.",
                controls: []
            )
        case .elevation:
            ReliefStyleGuideEntry(
                shows: "Height above sea level as colour, stretched to the range of what is on screen.",
                reading: "The palette runs from the lowest visible ground to the highest; the scale re-fits as you pan and zoom.",
                bestFor: "Telling higher ground from lower: floodplain versus terrace, valley floor versus ridge.",
                controls: ["Elevation Palette (Settings): Topo, Turbo, Slate or Magma"]
            )
        case .topographicOpenness:
            ReliefStyleGuideEntry(
                shows: "How exposed each spot is compared with the terrain around it, independent of any light.",
                reading: "Red is exposed, convex ground (ridges, mound tops); blue is enclosed, concave ground (ditches, valleys); white is flat or evenly sloping.",
                bestFor: "Picking out ridges and channels without the orientation bias of a sun.",
                controls: []
            )
        case .rrim:
            ReliefStyleGuideEntry(
                shows: "Red Relief Image Map: steepness as red, combined with openness as light and dark.",
                reading: "Steep faces are red, raised tops read bright, hollows and ditches read dark, and flat ground is mid-grey. No sun needed.",
                bestFor: "An all-round survey view for earthworks: embankments, terraces, sunken roads and pits.",
                controls: ["Openness Radius (Settings): larger picks up broad landforms, smaller sharpens small features"]
            )
        case .localRelief:
            ReliefStyleGuideEntry(
                shows: "Local Relief Model: height above or below the smoothed local ground, with the regional slope removed.",
                reading: "Mid-grey is level with its surroundings, bright is raised (mounds, embankments, levees) and dark is sunken (ditches, pits).",
                bestFor: "Low mounds and shallow ditches, even on sloping ground where other views lose them.",
                controls: [
                    "Smoothing Radius (Settings): set it larger than the features you are looking for",
                    "Contrast Scale (Settings): the height difference that shows as pure white or black; lower it for subtle features",
                ]
            )
        case .skyView:
            ReliefStyleGuideEntry(
                shows: "Sky-View Factor: how much of the sky is visible from each spot.",
                reading: "White is open ground; the darker it gets, the more enclosed: ditches, sunken trails and the foot of banks.",
                bestFor: "Hollow and sunken features, in a view that does not depend on light direction.",
                controls: ["Sky-View Radius (Settings): how far around each spot to look for a horizon"]
            )
        case .rakingLight:
            ReliefStyleGuideEntry(
                shows: "Hillshade with a very low sun and exaggerated height, like torchlight skimming across the ground.",
                reading: "Tiny bumps catch bright highlights and deep grazing shadows. Anything running parallel to the light vanishes, so sweep the sun around.",
                bestFor: "Faint linear features: old field boundaries, ridge-and-furrow, wheel ruts and low walls.",
                controls: [
                    "Sun direction slider (dock)",
                    "Grazing Sun Altitude (Settings): lower means sharper grazing contrast",
                    "Vertical Exaggeration (Settings): stretches heights to make small relief visible",
                ]
            )
        case .relativeElevation:
            ReliefStyleGuideEntry(
                shows: "Relative Elevation Model: height above the nearby river rather than above sea level.",
                reading: "Colour bands show metres above the water line. Levees (2 to 5 m up) separate from old channels and swales (at or below water level).",
                bestFor: "Floodplains: old river channels, oxbows, levees and terraces.",
                controls: [
                    "Draw River Thalweg (Settings): trace the channel's deepest line. Without one, height is measured from the lowest ground in view",
                    "Band Width (Settings): the height of each colour band; 0 gives smooth colour",
                ]
            )
        case .curvature:
            ReliefStyleGuideEntry(
                shows: "How the ground bends along the direction of the slope.",
                reading: "Red is convex (crests, the tops of banks), blue is concave (hollows, channel floors, the foot of slopes) and grey is a plain surface.",
                bestFor: "Outlining the edges of platforms, terraces and ditches, where the slope suddenly changes.",
                controls: []
            )
        case .directionalOcclusion:
            ReliefStyleGuideEntry(
                shows: "Real cast shadows from a low sun: ground that the surrounding terrain hides from the light is dark.",
                reading: "Bright ground is lit; dark ground sits in shadow behind banks, walls and mounds. Shadows fall away from the sun, which you move with the dock's sun slider.",
                bestFor: "Seeing banks and low walls by the shadows they throw, even from a distance.",
                controls: [
                    "Sun direction slider (dock): a bank running parallel to the light throws no shadow, so sweep the sun around",
                    "Grazing Sun Altitude (Settings): lower means longer shadows",
                ]
            )
        case .positiveOpenness:
            ReliefStyleGuideEntry(
                shows: "How open the view upward to the sky is from each spot, as a grey scale.",
                reading: "The brighter, the more exposed and convex: mound crowns, ridge crests and the tops of banks stand out.",
                bestFor: "Isolating raised features such as mounds, embankments and ridge lines.",
                controls: []
            )
        case .negativeOpenness:
            ReliefStyleGuideEntry(
                shows: "The mirror of Positive Openness: how much the surrounding terrain rises around each spot.",
                reading: "The brighter, the more enclosed: ditches, channels, pits and hollows light up.",
                bestFor: "Isolating sunken features such as ditches, moats, pits and old channels.",
                controls: []
            )
        case .vectorRuggedness:
            ReliefStyleGuideEntry(
                shows: "Vector Ruggedness Measure: how much the surface direction varies within a few metres, whatever the steepness.",
                reading: "Dark is smooth, even on a steep but even slope; bright is rough, broken ground.",
                bestFor: "Telling disturbed ground (rubble, eroded ditch remnants, tree throws) from smooth fields and slopes.",
                controls: []
            )
        case .differenceOfGaussians:
            ReliefStyleGuideEntry(
                shows: "A filter that keeps only features roughly 2 to 10 m across, removing both tiny bumps and broad landforms.",
                reading: "Bright is a narrow raised feature, dark is a narrow sunken one, and mid-grey is everything else.",
                bestFor: "Narrow linear features: sunken lanes, wheel ruts, small ditches and palisade lines.",
                controls: []
            )
        }
    }
}

public extension ReliefStyleGuide {

    /// The styles in `section` whose guide text matches `query`, in dock
    /// order; every style in the section when the query is blank.
    static func styles(in section: Section, matching query: String) -> [ReliefStyle] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return section.styles }
        return section.styles.filter { style in
            style.guideSearchText.contains { $0.localizedStandardContains(needle) }
        }
    }

    /// Overlays whose name or explanation matches `query`; every overlay when
    /// the query is blank.
    static func overlays(matching query: String) -> [Overlay] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Self.overlays }
        return Self.overlays.filter {
            $0.name.localizedStandardContains(needle) || $0.explanation.localizedStandardContains(needle)
        }
    }
}

extension ReliefStyle {

    /// The text the Map Styles reference searches.
    ///
    /// Leaves out the Adjust-with lines: nearly all of them say "Settings" or
    /// "slider", which would make those words match almost every style.
    var guideSearchText: [String] {
        let entry = guide
        return [displayName, dockLabel, entry.shows, entry.reading, entry.bestFor]
    }
}
