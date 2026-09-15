//
//  VisualPrimerView.swift
//  LidarExplorer
//
//  Visual guide explaining bare-earth lidar and relief shading.
//

import SwiftUI

/// The lidar guide: two primer slides on bare-earth lidar and relighting, then
/// a reference page explaining every map style and overlay.
///
/// Shown automatically on first launch and accessible anytime from the help button.
public struct VisualPrimerView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    slideOne.tag(0)
                    slideTwo.tag(1)
                    stylesPage.tag(Self.stylesPageTag)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                bottomBar
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Lidar Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if currentPage != Self.stylesPageTag {
                        Button("Map Styles") {
                            withAnimation { currentPage = Self.stylesPageTag }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Slide 1: Bare-Earth Concept

    private var slideOne: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .frame(width: 180, height: 130)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "tree.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.green.opacity(0.4))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "mountain.2.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue)
                    }

                    Text("Foliage Stripped")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                Text("See Beneath the Canopy")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Text("USGS 3DEP bare-earth lidar digitally strips away vegetation and structures, revealing subtle earthworks, foundations, fault lines, and terrain contours hidden to aerial photography.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding(.bottom, 20)
    }

    // MARK: - Slide 2: Dynamic Relighting

    private var slideTwo: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .frame(width: 180, height: 130)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

                VStack(spacing: 10) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)

                    Text("Raking Light Shadows")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                Text("Relighting the Ground")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Ridges and ditches parallel to the sun cast no shadows and vanish. Raking light across them makes subtle relief pop immediately. Sweep the sun slider to uncover hidden contours.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding(.bottom, 20)
    }

    // MARK: - Page 3: Map Styles

    private static let stylesPageTag = 2

    private var stylesPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Map Styles")
                        .font(.title2.weight(.bold))
                    Text("Pick a style from the chips in the dock at the bottom of the map. Each card shows the chip's label, what the style shows, how to read it and what it is good for.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ForEach(ReliefStyleGuide.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.headline)
                            Text(section.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(section.styles) { style in
                            StyleGuideCard(style: style)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overlays")
                            .font(.headline)
                        Text("Layers you switch on in Settings. Contour lines work with every style; the mask and sky-view shading work with the micro-topography styles.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ReliefStyleGuide.overlays) { overlay in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(overlay.name)
                                .font(.subheadline.weight(.semibold))
                            Text(overlay.explanation)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            // Clear of the page indicator dots.
            .padding(.bottom, 44)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Divider()

            Button {
                dismiss()
            } label: {
                Text("Start Exploring")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

/// One style's card on the Map Styles page.
private struct StyleGuideCard: View {
    let style: ReliefStyle

    var body: some View {
        let entry = style.guide
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(style.dockLabel)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Text(style.displayName)
                    .font(.subheadline.weight(.semibold))
            }
            Text(entry.shows)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            row("How to read it", entry.reading)
            row("Best for", entry.bestFor)
            if !entry.controls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Adjust with")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(entry.controls, id: \.self) { control in
                        Label(control, systemImage: "slider.horizontal.3")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
