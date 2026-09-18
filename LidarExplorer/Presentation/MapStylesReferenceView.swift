//
//  MapStylesReferenceView.swift
//  LidarExplorer
//
//  Searchable reference for every map style and overlay, shown beside the map.
//

import SwiftUI

/// What each map style shows and when to use it.
///
/// ``TerrainViewerView`` presents this as an inspector: a trailing column on
/// iPad, a sheet on compact widths. Because it may itself be a sheet, the intro
/// it replays is presented from here. A request to the map screen's root
/// `.sheet` would be dropped while this sheet is up.
public struct MapStylesReferenceView: View {

    let model: TerrainViewerModel
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var path: [Destination] = []
    @State private var showsIntro = false

    private enum Destination: Hashable {
        case style(ReliefStyle)
        case overlay(String)
    }

    public init(model: TerrainViewerModel, isPresented: Binding<Bool>) {
        self.model = model
        self._isPresented = isPresented
        #if DEBUG
        if let q = ProcessInfo.processInfo.environment["STYLE_REF_QUERY"] {
            self._query = State(initialValue: q)
        }
        if let styleName = ProcessInfo.processInfo.environment["STYLE_REF_DETAIL"],
           let style = ReliefStyle.allCases.first(where: { $0.displayName == styleName || $0.dockLabel == styleName }) {
            self._path = State(initialValue: [.style(style)])
        }
        if ProcessInfo.processInfo.environment["STYLE_REF_INTRO"] == "1" {
            self._showsIntro = State(initialValue: true)
        }
        #endif
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                list
                    // Reopening starts at the list, scrolled to the style in use.
                    .onAppear { proxy.scrollTo(model.style, anchor: .center) }
            }
            .navigationTitle("Map Styles")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search styles")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Map Styles")
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .style(let style):
                    StyleDetailView(model: model, style: style)
                case .overlay(let name):
                    if let overlay = ReliefStyleGuide.overlays.first(where: { $0.name == name }) {
                        OverlayDetailView(overlay: overlay)
                    }
                }
            }
        }
        .sheet(isPresented: $showsIntro) {
            VisualPrimerView()
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasResults: Bool {
        ReliefStyleGuide.sections.contains { !ReliefStyleGuide.styles(in: $0, matching: query).isEmpty }
            || !ReliefStyleGuide.overlays(matching: query).isEmpty
    }

    private var list: some View {
        List {
            ForEach(ReliefStyleGuide.sections) { section in
                let styles = ReliefStyleGuide.styles(in: section, matching: query)
                if !styles.isEmpty {
                    Section {
                        ForEach(styles) { style in
                            NavigationLink(value: Destination.style(style)) {
                                StyleRow(style: style, isInUse: model.style == style)
                            }
                            .id(style)
                        }
                    } header: {
                        Text(section.title)
                    } footer: {
                        Text(section.subtitle)
                    }
                }
            }

            let overlays = ReliefStyleGuide.overlays(matching: query)
            if !overlays.isEmpty {
                Section("Overlays") {
                    ForEach(overlays) { overlay in
                        NavigationLink(overlay.name, value: Destination.overlay(overlay.name))
                    }
                }
            }

            if !isSearching {
                Section {
                    Button("Replay Intro") { showsIntro = true }
                }
            }
        }
        .overlay {
            if !hasResults {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

// MARK: - Rows

private struct StyleRow: View {
    let style: ReliefStyle
    let isInUse: Bool

    var body: some View {
        HStack(spacing: 10) {
            StyleChip(style: style)
            Text(style.displayName)
            Spacer(minLength: 8)
            if isInUse {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isInUse ? "In use" : "")
    }
}

/// The style's dock chip label, styled like a chip.
private struct StyleChip: View {
    let style: ReliefStyle

    var body: some View {
        Text(style.dockLabel)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

// MARK: - Detail pages

private struct StyleDetailView: View {
    let model: TerrainViewerModel
    let style: ReliefStyle

    var body: some View {
        let entry = style.guide
        let isInUse = model.style == style
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    StyleChip(style: style)
                    Text(style.displayName)
                        .font(.title3.weight(.semibold))
                }
                Text(entry.shows)
                GuideParagraph(title: "How to read it", text: entry.reading)
                GuideParagraph(title: "Best for", text: entry.bestFor)
                if !entry.controls.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Adjust with")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(entry.controls, id: \.self) { control in
                            Label(control, systemImage: "slider.horizontal.3")
                                .font(.subheadline)
                        }
                    }
                }
                Button {
                    model.style = style
                } label: {
                    Label(isInUse ? "In Use" : "Use This Style",
                          systemImage: isInUse ? "checkmark.circle.fill" : "map")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isInUse)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(style.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OverlayDetailView: View {
    let overlay: ReliefStyleGuide.Overlay

    var body: some View {
        ScrollView {
            Text(overlay.explanation)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(overlay.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GuideParagraph: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}
