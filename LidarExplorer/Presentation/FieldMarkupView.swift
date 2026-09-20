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

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(MarkupTool.allCases, id: \.self) { tool in
                    Button {
                        model.markupTool = tool
                    } label: {
                        Image(systemName: tool.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(model.markupTool == tool ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
                    }
                    .accessibilityLabel(tool.label)
                }

                Divider().frame(height: 24)

                ForEach(Self.swatches, id: \.self) { hex in
                    Button {
                        model.markupColorHex = hex
                    } label: {
                        Circle()
                            .fill(Color(markupHex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.primary.opacity(model.markupColorHex == hex ? 0.9 : 0.25), lineWidth: 2))
                    }
                    .accessibilityLabel("Ink colour \(hex)")
                }
            }

            HStack(spacing: 10) {
                Button {
                    waypointTitle = "Waypoint \(model.fieldWaypoints.count + 1)"
                    waypointNotes = ""
                    showsWaypointForm = true
                } label: {
                    Label("Waypoint", systemImage: "mappin.and.ellipse")
                }
                Button {
                    model.undoFieldMarkup()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.hasFieldMarkup)
                Button(role: .destructive) {
                    showsClearConfirmation = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(!model.hasFieldMarkup)
                Button {
                    Task { await model.shareFieldMarkup() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.hasFieldMarkup || model.isPreparingExport)
                Spacer(minLength: 0)
                Button("Done") { model.isMarkingUp = false }
                    .buttonStyle(.borderedProminent)
            }
            .labelStyle(.iconOnly)
            .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
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

private extension Color {
    init(markupHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0xFFFFFF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
