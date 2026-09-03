//
//  OnboardingView.swift
//  LidarExplorer
//
//  First-run explanation of the terrain controls.
//

import SwiftUI

/// Explains what the shading controls do and why they matter.
///
/// Shown once automatically, and reachable afterwards from the help button.
/// There is no "don't show again" checkbox because there is nothing to
/// suppress: it never appears uninvited a second time.
public struct OnboardingView: View {

    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    header

                    section(
                        icon: "sun.max",
                        title: "Azimuth — where the light comes from",
                        body: """
                        The compass direction the imaginary sun sits in, \
                        0° being north.

                        This matters more than it sounds. A ridge, bank or \
                        ditch lit along its length casts almost no shadow and \
                        can vanish completely; the same feature lit across it \
                        stands out immediately. If you are looking for \
                        something subtle, sweep the azimuth slider and watch \
                        what appears and disappears.
                        """
                    )

                    section(
                        icon: "angle",
                        title: "Sun angle — how high it sits",
                        body: """
                        The light's height above the horizon.

                        Low angles rake across the ground and throw long \
                        shadows, exaggerating shallow relief — good for faint \
                        earthworks and plough marks. High angles flatten the \
                        shadows and show broad shape instead. Around 30–40° \
                        suits most terrain.
                        """
                    )

                    section(
                        icon: "circle.grid.cross",
                        title: "Multi-directional — no single light",
                        body: """
                        Instead of one sun, this combines several directions \
                        and maps how much the brightness varies between them.

                        Because it is not tied to any one angle, nothing hides \
                        by lying parallel to the light. It is the best starting \
                        point for finding features, and the reason it is the \
                        default. Switch to Hillshade once you have spotted \
                        something and want to see its form.
                        """
                    )

                    section(
                        icon: "square.3.layers.3d",
                        title: "Slope and Elevation",
                        body: """
                        Slope colours the ground by steepness, which picks out \
                        edges, scarps and terracing that shading can flatten.

                        Elevation tints by height, useful for reading the \
                        overall lie of the land rather than fine detail.
                        """
                    )

                    section(
                        icon: "hand.tap",
                        title: "Reading the ground",
                        body: """
                        Tap anywhere to read the elevation at that point.

                        Detail follows the zoom automatically. Zoomed out you \
                        get fast, coarse terrain; as you move in it sharpens, \
                        reaching about one metre per pixel at the deepest \
                        zoom. There is nothing to load — it streams as you pan.
                        """
                    )

                    footnote
                }
                .padding(24)
            }
            .navigationTitle("Reading the terrain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got it") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This is bare-earth lidar.")
                .font(.title3.weight(.semibold))
            Text("""
                The surface you are looking at has had vegetation and \
                buildings stripped out, leaving the shape of the ground \
                itself. Things invisible under tree cover — old field \
                boundaries, quarry edges, earthworks — often show up plainly.
                """)
                .foregroundStyle(.secondary)
        }
    }

    private func section(icon: String, title: String, body text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Elevation data: USGS 3DEP and AWS Terrain Tiles. Basemaps: The National Map, USGS.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("You can reopen this any time from the ? button in the controls.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
