//
//  OfflineHarvestView.swift
//  LidarExplorer
//
//  Download the area on the map for use with no signal: choose how deep to zoom, see what it will cost, run it,
//  pause it, stop it and pick it up again. What decides is in OfflineHarvestController.
//

import SwiftUI

struct OfflineHarvestView: View {

    let model: TerrainViewerModel
    @Bindable var controller: OfflineHarvestController

    var body: some View {
        Form {
            areaSection
            detailSection
            if controller.canIncludeBasemaps { basemapSection }
            sizeSection
            controlSection
            resultSection
        }
        .navigationTitle("Offline Download")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !controller.isBusy else { return }
            controller.environment = model.harvestEnvironment()
            controller.choose(region: model.visibleGeoRegion, viewportWidthPoints: model.mapWidthPoints)
            await controller.refreshEstimate()
        }
        .onChange(of: controller.minZ) { _, _ in resize() }
        .onChange(of: controller.maxZ) { _, _ in resize() }
        .onChange(of: controller.includeBasemaps) { _, _ in resize() }
    }

    private func resize() {
        guard !controller.isBusy else { return }
        Task { await controller.refreshEstimate() }
    }

    // MARK: - Sections

    private var areaSection: some View {
        Section {
            LabeledContent("Centre", value: String(format: "%.4f°, %.4f°", controller.region.centerLatitude, controller.region.centerLongitude))
            LabeledContent("Size", value: "\(Self.length(controller.region.widthMeters)) × \(Self.length(controller.region.heightMeters))")
            if !controller.isBusy {
                Button("Use What the Map Shows") {
                    controller.choose(region: model.visibleGeoRegion, viewportWidthPoints: model.mapWidthPoints)
                    resize()
                }
            }
        } header: {
            Text("Area")
        } footer: {
            Text("The area is what the map showed when Settings opened. Close Settings, move the map and open this again to choose another.")
        }
    }

    private var detailSection: some View {
        Section {
            Stepper("Zoom out to level \(controller.minZ)", value: $controller.minZ, in: OfflineHarvestController.zoomLimits)
            Stepper("Zoom in to level \(controller.maxZ)", value: $controller.maxZ, in: OfflineHarvestController.zoomLimits)
        } header: {
            Text("Detail")
        } footer: {
            Text("Each level down is about four times the tiles. Level 18 and deeper is where 1 m lidar shows.")
        }
        .disabled(controller.isBusy)
    }

    private var basemapSection: some View {
        Section {
            Toggle("Also keep the \(controller.environment.basemapName ?? "basemap") basemap", isOn: $controller.includeBasemaps)
        } footer: {
            Text("Only the USGS basemaps can be kept. Apple's imagery cannot, so with it selected this is not offered.")
        }
        .disabled(controller.isBusy)
    }

    private var sizeSection: some View {
        Section("Size") {
            if let estimate = controller.estimate {
                LabeledContent("Tiles", value: estimate.tileCount.formatted())
                LabeledContent("About", value: ByteCountFormatter.string(fromByteCount: estimate.totalBytes, countStyle: .file))
            }
            if let blocker = controller.blocker {
                Text(blocker.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var controlSection: some View {
        Section {
            switch controller.phase {
            case .running, .paused:
                if let progress = controller.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.processed), total: Double(max(progress.total, 1)))
                        Text("\(progress.processed.formatted()) of \(progress.total.formatted()) tiles"
                             + (progress.failed > 0 ? " · \(progress.failed.formatted()) failed" : "")
                             + (controller.phase == .running ? String(format: " · %.0f KB/s", progress.kilobytesPerSecond) : " · paused"))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Starting…")
                    }
                }
                if controller.phase == .paused {
                    Button("Resume") { controller.resume() }
                } else {
                    Button("Pause") { controller.pause() }
                }
                Button("Stop", role: .destructive) { controller.cancel() }
            case .idle, .finished, .failed:
                Button {
                    Task { await controller.start() }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(!controller.canStart)
                if controller.canResume {
                    Button {
                        Task { await controller.resumeInterrupted() }
                    } label: {
                        Label("Continue the Last Download", systemImage: "arrow.clockwise.circle")
                    }
                }
            }
        } footer: {
            Text("Keep the app open while it downloads: the screen will not lock, and iPadOS pauses downloads when an app is in the background. Stopping keeps what is done.")
        }
    }

    @ViewBuilder private var resultSection: some View {
        switch controller.phase {
        case .finished(let summary):
            Section("Result") {
                Text(Self.description(of: summary))
                    .font(.footnote)
            }
        case .failed(let message):
            Section("Result") {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        case .idle, .running, .paused:
            EmptyView()
        }
    }

    // MARK: - Words

    private static func length(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : String(format: "%.0f m", meters)
    }

    private static func description(of summary: HarvestSummary) -> String {
        let stored = ByteCountFormatter.string(fromByteCount: summary.bytesStored, countStyle: .file)
        switch summary.state {
        case .completed where summary.failed == 0:
            return "Downloaded all \(summary.total.formatted()) tiles. This run stored \(stored); tiles already on the disk were not fetched again."
        case .completed:
            return "Downloaded \(summary.completed.formatted()) of \(summary.total.formatted()) tiles; "
                + "\(summary.failed.formatted()) could not be downloaded. Continue the last download to try those again. "
                + "This run stored \(stored)."
        case .cancelled:
            return "Stopped with \(summary.completed.formatted()) of \(summary.total.formatted()) tiles done. "
                + "Continue the last download to finish. This run stored \(stored)."
        }
    }
}
