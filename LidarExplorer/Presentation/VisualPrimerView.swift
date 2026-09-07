//
//  VisualPrimerView.swift
//  LidarExplorer
//
//  Visual guide explaining bare-earth lidar and relief shading.
//

import SwiftUI

/// A 2-slide visual primer demonstrating bare-earth lidar and dynamic relighting.
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
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                bottomBar
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Lidar Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
