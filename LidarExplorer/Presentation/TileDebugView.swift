//
//  TileDebugView.swift
//  LidarExplorer
//
//  Live view of tile loading, for diagnosis on device.
//

import SwiftUI

/// Shows what the terrain layer is fetching, as it happens.
///
/// Recording starts when this view appears and keeps running after it is
/// dismissed, because the activity worth diagnosing — what a pan or a zoom
/// sets off — happens while this panel is *not* on screen: it is a sheet, and
/// it covers the map it is reporting on. Switch it off here when done; until
/// then the provider's reporting hook stays live, which is the whole cost.
/// Nothing is persisted or sent anywhere.
public struct TileDebugView: View {

    @Bindable var log: TileActivityLog
    @Environment(\.dismiss) private var dismiss

    public init(log: TileActivityLog) {
        self.log = log
    }

    public var body: some View {
        NavigationStack {
            Group {
                if log.entries.isEmpty {
                    ContentUnavailableView(
                        "No tiles yet",
                        systemImage: "square.grid.3x3",
                        description: Text(
                            log.isRecording
                            ? "Recording. Close this panel, pan or zoom the map, then come back."
                            : "Turn on Recording, close this panel, then pan or zoom the map."
                        )
                    )
                } else {
                    List {
                        Section("Summary") {
                            summaryRow("Fetched", "\(log.fetchedCount)")
                            summaryRow("From cache", "\(log.cachedCount)")
                            summaryRow("Cancelled", "\(log.cancelledCount)")
                            summaryRow("Failed", "\(log.failedCount)")
                            if let average = log.averageFetchSeconds {
                                summaryRow("Mean fetch", String(format: "%.2f s", average))
                            }
                            summaryRow("Data", String(format: "%.1f MB",
                                                      Double(log.totalBytes) / 1_048_576))
                        }
                        Section("Tiles — newest first") {
                            ForEach(log.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tile activity")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Toggle("Recording", isOn: $log.isRecording)
                    .padding()
                    .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { log.clear() }
                        .disabled(log.entries.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Deliberately not stopped on dismiss: see the type's note.
            .onAppear { log.isRecording = true }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func row(_ entry: TileActivityLog.Entry) -> some View {
        let event = entry.event
        return HStack(spacing: 10) {
            Image(systemName: icon(for: event.outcome))
                .foregroundStyle(colour(for: event.outcome))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("z\(event.z)  \(event.x), \(event.y)")
                    .font(.callout.monospacedDigit())
                HStack(spacing: 6) {
                    Text(event.source)
                    if let resolution = event.resolution {
                        Text(String(format: "· %.2f m/px", resolution))
                    }
                    if let backend = event.backend {
                        Text("· \(backend.rawValue.uppercased())")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f ms", event.duration * 1000))
                    .font(.caption.monospacedDigit())
                if let bytes = event.byteCount {
                    Text("\(bytes / 1024) KB")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func icon(for outcome: TileEvent.Outcome) -> String {
        switch outcome {
        case .fetched: "arrow.down.circle"
        case .cached: "bolt.circle"
        case .cancelled: "arrow.uturn.backward.circle"
        case .failed: "xmark.circle"
        }
    }

    private func colour(for outcome: TileEvent.Outcome) -> Color {
        switch outcome {
        case .fetched: .blue
        case .cached: .green
        case .cancelled: .secondary
        case .failed: .orange
        }
    }
}
