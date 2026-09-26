//
//  FieldMarkupView.swift
//  LidarExplorer
//
//  The field notebook's controls: ink, waypoint, undo, clear and export. The drawing itself is
//  ``PencilMarkupCanvas``, layered over the map by the viewer.
//

import CoreLocation
import MapKit
import SwiftUI

public struct FieldMarkupToolbarView: View {

    @Bindable var model: TerrainViewerModel
    @State private var showsWaypointForm = false
    @State private var showsClearConfirmation = false
    @State private var waypointTitle = ""
    @State private var waypointNotes = ""

    private static let swatches = ["#FF3B30", "#FFD60A", "#32D7FF", "#34C759", "#FFFFFF"]
    private static let swatchNames = [
        "#FF3B30": "Red", "#FFD60A": "Yellow", "#32D7FF": "Cyan", "#34C759": "Green", "#FFFFFF": "White",
    ]

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 8) {
            // No gaps: the 44 pt tool and 36 pt swatch frames space the row themselves, and it fits
            // a 375 pt iPhone in portrait (3 x 44 + 5 x 36 + the divider, about 319 pt).
            HStack(spacing: 0) {
                ForEach(MarkupTool.allCases, id: \.self) { tool in
                    Button {
                        model.markupTool = tool
                    } label: {
                        Image(systemName: tool.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(model.markupTool == tool ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(tool.label)
                    .accessibilityAddTraits(model.markupTool == tool ? .isSelected : [])
                }

                Divider().frame(height: 24).padding(.horizontal, 3)

                ForEach(Self.swatches, id: \.self) { hex in
                    Button {
                        model.markupColorHex = hex
                    } label: {
                        // The selection ring sits outside the ink, over the glass, so it shows on
                        // every ink in both appearances (a white ring inside the White ink did not).
                        Circle()
                            .fill(Color(markupHex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 2))
                            .padding(4)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(model.markupColorHex == hex ? 0.9 : 0), lineWidth: 2))
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(Self.swatchNames[hex] ?? hex) ink")
                    .accessibilityAddTraits(model.markupColorHex == hex ? .isSelected : [])
                }
            }

            // No gaps here either: each 44 pt target spaces the row itself, which leaves the Done
            // button room on a 375 pt iPhone at large text sizes.
            HStack(spacing: 0) {
                Button {
                    waypointTitle = "Waypoint \(model.fieldWaypoints.count + 1)"
                    waypointNotes = ""
                    showsWaypointForm = true
                } label: {
                    Label("Waypoint", systemImage: "mappin.and.ellipse")
                        .actionTarget()
                }
                Button {
                    model.undoFieldMarkup()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .actionTarget()
                }
                .disabled(!model.hasFieldMarkup)
                Button(role: .destructive) {
                    showsClearConfirmation = true
                } label: {
                    Label("Clear", systemImage: "trash")
                        .actionTarget()
                }
                .disabled(!model.hasFieldMarkup)
                Button {
                    Task { await model.shareFieldMarkup() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .actionTarget()
                }
                .disabled(!model.hasFieldMarkup || model.isPreparingExport)
                Spacer(minLength: 0)
                Button("Done") { model.isMarkingUp = false }
                    .buttonStyle(.borderedProminent)
            }
            .labelStyle(.iconOnly)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        }
        // The targets are fixed 44 pt frames, so the glyphs stop growing before they outgrow them.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(12)
        .glassPanel()
        .padding(.horizontal, 16)
        .alert("New waypoint", isPresented: $showsWaypointForm) {
            TextField("Title", text: $waypointTitle)
            TextField("Notes", text: $waypointNotes)
            Button("Add") {
                let centre = model.visibleRegion.center
                let title = waypointTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = waypointNotes
                Task { await model.addFieldWaypoint(at: centre, title: title.isEmpty ? "Waypoint" : title, notes: notes) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Drops a pin at the middle of the map, with the ground height under it.")
        }
        .confirmationDialog("Clear all markup?", isPresented: $showsClearConfirmation, titleVisibility: .visible) {
            Button("Clear all lines and waypoints", role: .destructive) { model.clearFieldMarkup() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private extension View {
    /// An icon-only action owns a full 44 x 44 pt target, not just its glyph's bounds.
    func actionTarget() -> some View {
        frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

private extension Color {
    init(markupHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0xFFFFFF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
