//
//  LandmarkCatalogView.swift
//  LidarExplorer
//
//  Catalog sheet showcasing curated geological and archaeological LiDAR sites and saved bookmarks.
//

import CoreLocation
import SwiftUI

public struct LandmarkCatalogView: View {

    @Bindable var model: TerrainViewerModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFilter: CategoryFilter = .all
    @State private var showingAddBookmark = false
    @State private var newBookmarkName = ""

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public enum CategoryFilter: Hashable, CaseIterable {
        case all
        case earthworks
        case volcanic
        case tectonic
        case craters
        case fluvial
        case custom

        public var title: String {
            switch self {
            case .all: return "All"
            case .earthworks: return "Earthworks"
            case .volcanic: return "Volcanic"
            case .tectonic: return "Tectonic"
            case .craters: return "Craters"
            case .fluvial: return "Rivers & Canyons"
            case .custom: return "My Bookmarks"
            }
        }

        public var category: Landmark.Category? {
            switch self {
            case .all: return nil
            case .earthworks: return .earthworks
            case .volcanic: return .volcanic
            case .tectonic: return .tectonic
            case .craters: return .craters
            case .fluvial: return .fluvial
            case .custom: return .custom
            }
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                categoryFilterBar
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .systemGroupedBackground))

                List {
                    if selectedFilter == .all || selectedFilter == .custom {
                        bookmarksSection
                    }

                    if selectedFilter != .custom {
                        curatedSection
                    }
                }
            }
            .navigationTitle("Explore LiDAR Sites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.showsLandmarks = false
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("Bookmark Current Location", isPresented: $showingAddBookmark) {
                TextField("Site Name", text: $newBookmarkName)
                Button("Save") {
                    model.saveBookmark(named: newBookmarkName)
                    newBookmarkName = ""
                }
                Button("Cancel", role: .cancel) {
                    newBookmarkName = ""
                }
            } message: {
                Text("Save the current map coordinate and azimuth angle to your bookmarks.")
            }
        }
    }

    // MARK: - Category Filter Bar

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CategoryFilter.allCases, id: \.self) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selectedFilter == filter ? Color.accentColor : Color.secondary.opacity(0.14),
                                in: Capsule()
                            )
                            .foregroundStyle(selectedFilter == filter ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Bookmarks Section

    private var bookmarksSection: some View {
        Section {
            Button {
                showingAddBookmark = true
            } label: {
                Label("Bookmark Current Location", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
            }

            if model.bookmarks.isEmpty {
                if selectedFilter == .custom {
                    Text("No saved bookmarks yet. Tap above to save your current view.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.bookmarks) { landmark in
                    landmarkRow(landmark)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let bookmark = model.bookmarks[index]
                        model.deleteBookmark(id: bookmark.id)
                    }
                }
            }
        } header: {
            HStack {
                Text("My Bookmarks")
                if !model.bookmarks.isEmpty {
                    Text("(\(model.bookmarks.count))")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Curated Sites Section

    private var curatedSites: [Landmark] {
        if let targetCategory = selectedFilter.category {
            return Landmark.curatedSites.filter { $0.category == targetCategory }
        }
        return Landmark.curatedSites
    }

    private var curatedSection: some View {
        Section {
            ForEach(curatedSites) { landmark in
                landmarkRow(landmark)
            }
        } header: {
            HStack {
                Text(selectedFilter == .all ? "Curated Geological & Archaeological Sites" : selectedFilter.title)
                Spacer()
                Text("\(curatedSites.count) sites")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Landmark Row

    private func landmarkRow(_ landmark: Landmark) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: landmark.category.iconName)
                .font(.title3)
                .foregroundStyle(categoryColor(landmark.category))
                .frame(width: 36, height: 36)
                .background(categoryColor(landmark.category).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(landmark.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(landmark.category.rawValue)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(categoryColor(landmark.category).opacity(0.12), in: Capsule())
                        .foregroundStyle(categoryColor(landmark.category))
                }

                Text(landmark.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Button {
                model.flyTo(landmark: landmark)
                dismiss()
            } label: {
                Text("Fly to Site")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            model.flyTo(landmark: landmark)
            dismiss()
        }
    }

    private func categoryColor(_ category: Landmark.Category) -> Color {
        switch category {
        case .earthworks:
            return .orange
        case .volcanic:
            return .red
        case .tectonic:
            return .purple
        case .craters:
            return .indigo
        case .fluvial:
            return .blue
        case .custom:
            return .teal
        }
    }
}
