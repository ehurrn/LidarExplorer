//
//  PersistenceChecks.swift
//  ViewerHarness
//
//  The field notebook on disk: its file format, the store that writes it without ever losing what was there, and
//  the viewer model that restores it at launch and saves after every change.
//
//  A stuck store must fail a check, not hang the harness, so every wait is a poll to a deadline.
//

import CoreGraphics
import CoreLocation
import Foundation

@MainActor
func runPersistenceChecks() async {
    print("\n=== Field notebook persistence ===")
    checkNotebookFormat()
    await checkNotebookStore()
    await checkNotebookModel()
    await checkNotebookSaveOrder()
    await checkNotebookFuzz()
}

// MARK: - Fixtures

private func line(_ vertices: Int = 3, from latitude: Double = 38.65, color: String = "#FF3B30", width: Double = 4.5) -> FieldAnnotationTrace {
    FieldAnnotationTrace(
        coordinates: (0..<vertices).map {
            CLLocationCoordinate2D(latitude: latitude + Double($0) * 0.0001, longitude: -90.06 + Double($0) * 0.0002)
        },
        strokeWidth: width, colorHex: color)
}

private func pin(_ title: String, elevation: Float? = 123.5) -> FieldWaypoint {
    FieldWaypoint(
        coordinate: CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621), elevationMeters: elevation,
        title: title, notes: "Line 1\nLine 2 \"quoted\" \\ 🏺", timestamp: Date(timeIntervalSince1970: 1_800_000_000.25),
        photoFilename: "IMG_0042.jpg")
}

/// Two traces and two waypoints, interleaved, because the order they were made in is what undo follows.
private func sampleNotebook() -> FieldNotebook {
    FieldNotebook(items: [
        .trace(line(3)), .waypoint(pin("A")),
        .trace(line(5, from: 38.7, color: "#ffd60a80", width: 18)), .waypoint(pin("B", elevation: nil)),
    ])
}

/// The notebook's file with `change` applied to its parsed top level.
private func mutated(_ notebook: FieldNotebook, _ change: (inout [String: Any]) -> Void) -> Data {
    guard let data = try? notebook.encoded(),
          var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Data() }
    change(&root)
    return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
}

private func decodeError(_ data: Data) -> FieldNotebook.DecodeError? {
    do {
        _ = try FieldNotebook.decode(data)
        return nil
    } catch {
        return error as? FieldNotebook.DecodeError
    }
}

private func isNotANotebook(_ data: Data) -> Bool {
    if case .notANotebook = decodeError(data) { return true }
    return false
}

// MARK: - P1. The file format

@MainActor
private func checkNotebookFormat() {
    print("\n--- P1. the file format ---")
    let notebook = sampleNotebook()
    let data = try? notebook.encoded()
    let back = data.flatMap { try? FieldNotebook.decode($0) }
    check("a notebook is read back exactly as it was saved: every item, in order, every field",
          back?.notebook == notebook && back?.dropped == 0 && notebook.traces.count == 2 && notebook.waypoints.count == 2,
          "\(String(describing: back?.dropped))")

    let root = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    let items = root?["items"] as? [[String: Any]]
    check("the file states its version and lists the items oldest first, each named for its kind",
          root?["version"] as? Int == FieldNotebook.currentVersion && FieldNotebook.currentVersion == 1
          && items?.compactMap({ $0["kind"] as? String }) == ["trace", "waypoint", "trace", "waypoint"],
          "\(String(describing: root?["version"])) \(String(describing: items?.count))")
    check("saving is deterministic, byte for byte, and an empty notebook is a valid file that reads back empty",
          (try? notebook.encoded()) == data && data != nil && !(data?.isEmpty ?? true)
          && ((try? FieldNotebook().encoded()).flatMap { try? FieldNotebook.decode($0) })?.notebook == FieldNotebook())

    // Values that are not numbers must not be able to stop a save: a save that throws would never happen again, and
    // the notebook would silently stop being kept.
    var nanTrace = line(3)
    nanTrace.positions[1].latitude = .nan
    nanTrace.strokeWidth = .infinity
    var nanPin = pin("N")
    nanPin.elevationMeters = .nan
    var farPin = pin("F")
    farPin.position.longitude = .infinity
    let hostile = FieldNotebook(items: [.trace(nanTrace), .waypoint(nanPin), .waypoint(farPin), .trace(line(3))])
    let hostileData = try? hostile.encoded()
    let cleaned = hostileData.flatMap { try? FieldNotebook.decode($0) }
    let firstTrace = cleaned?.notebook.traces.first
    check("values that are not numbers do not stop a save, and are cleaned out on the way back: the bad vertex, width and elevation go, the item that is nowhere is dropped",
          hostileData != nil && cleaned?.notebook.items.count == 3 && cleaned?.dropped == 1
          && firstTrace?.positions.count == 2 && firstTrace?.strokeWidth == 4
          && cleaned?.notebook.waypoints.first?.elevationMeters == nil && cleaned?.notebook.waypoints.first?.title == "N",
          "\(String(describing: cleaned?.notebook.items.count)) items, \(String(describing: cleaned?.dropped)) dropped")

    var badPin = pin("bad")
    badPin.position.latitude = 91
    var halfTrace = line(4)
    halfTrace.positions[1].longitude = 500
    var stub = line(3)
    stub.positions[0].latitude = -200
    stub.positions[2].longitude = 999
    var pale = line(3, color: "red")
    pale.strokeWidth = 1e308
    let twin = line(3)
    let messy = FieldNotebook(items: [.waypoint(badPin), .trace(halfTrace), .trace(stub), .trace(pale), .trace(twin), .trace(twin)])
    let tidy = messy.sanitized()
    let byID = Dictionary(tidy.notebook.traces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    check("reading drops what is not a place, a line or an identity of its own: 3 of 6 items, and keeps what can be kept of the rest",
          tidy.dropped == 3 && tidy.notebook.items.count == 3 && byID[halfTrace.id]?.positions.count == 3
          && byID[stub.id] == nil && byID[twin.id] != nil,
          "\(tidy.dropped) dropped, \(tidy.notebook.items.count) kept")
    check("a colour that is not hex becomes the default ink and an absurd width is clamped to a pen's range",
          byID[pale.id]?.colorHex == FieldMarkup.defaultInkHex && byID[pale.id]?.strokeWidth == 1000
          && FieldMarkup.defaultInkHex == "#FF3B30" && FieldMarkup.isValidColorHex("#FFD60A80") && !FieldMarkup.isValidColorHex("red"))

    // One bad item costs only itself.
    let oneBad = mutated(notebook) { root in
        var list = root["items"] as? [[String: Any]] ?? []
        guard list.count > 1 else { return }
        var waypoint = list[1]["waypoint"] as? [String: Any] ?? [:]
        waypoint["title"] = 5
        list[1]["waypoint"] = waypoint
        root["items"] = list
    }
    let partial = try? FieldNotebook.decode(oneBad)
    check("an item that cannot be read costs only itself, and the rest keep their order",
          partial?.dropped == 1 && partial?.notebook.items == [notebook.items[0], notebook.items[2], notebook.items[3]],
          "\(String(describing: partial?.dropped)) dropped")
    let unknownKind = mutated(notebook) { root in
        var list = root["items"] as? [[String: Any]] ?? []
        list.append(["kind": "photo", "photo": ["file": "x.jpg"]])
        root["items"] = list
    }
    let skipped = try? FieldNotebook.decode(unknownKind)
    check("an item of a kind this version does not know is skipped, not fatal",
          skipped?.dropped == 1 && skipped?.notebook == notebook)

    // Files that are not notebooks at all.
    let good = data ?? Data()
    let truncated = good.prefix(good.count / 2)
    let notNotebooks: [(String, Data)] = [
        ("garbage bytes", Data((0..<64).map { UInt8(($0 * 7 + 3) & 0xff) })),
        ("an empty file", Data()),
        ("a file cut off in the middle", Data(truncated)),
        ("a JSON array", Data("[]".utf8)),
        ("no version", Data("{\"items\":[]}".utf8)),
        ("a version that is a string", Data("{\"version\":\"1\",\"items\":[]}".utf8)),
        ("version 0", Data("{\"version\":0,\"items\":[]}".utf8)),
        ("no items", Data("{\"version\":1}".utf8)),
    ]
    let refusals = notNotebooks.filter { !isNotANotebook($0.1) }.map(\.0)
    check("a file that is not a notebook is refused, whatever it is: garbage, empty, cut off, wrong shape, no version",
          refusals.isEmpty, "not refused: \(refusals)")
    let newer = mutated(notebook) { $0["version"] = FieldNotebook.currentVersion + 1 }
    check("a file from a later version is refused as such, not misread",
          decodeError(newer) == .unsupportedVersion(FieldNotebook.currentVersion + 1))

    let big = FieldNotebook(items: (0..<500).map { .trace(line(120, from: 38 + Double($0) * 0.0001)) })
    let bigBack = (try? big.encoded()).flatMap { try? FieldNotebook.decode($0) }
    check("a notebook of 500 traces of 120 points round-trips exactly",
          bigBack?.notebook == big && bigBack?.dropped == 0 && big.items.count == 500)
}

// MARK: - Helpers for the store and the model

private func notebookFile(_ directory: URL) -> URL { directory.appendingPathComponent("FieldNotebook.json") }

private func storeIn(_ directory: URL, delay: Duration = .milliseconds(400)) -> FieldNotebookStore {
    FieldNotebookStore(fileURL: notebookFile(directory), saveDelay: delay)
}

private func names(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

private func readNotebook(_ url: URL) -> FieldNotebook? {
    (try? Data(contentsOf: url)).flatMap { try? FieldNotebook.decode($0) }?.notebook
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func setPermissions(_ url: URL, _ mode: Int) {
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

/// Runs as root, where permission bits do not stop a read or a write, so the checks built on them cannot fail.
private var runsAsRoot: Bool { getuid() == 0 }

/// Polls to a deadline, so a stuck store fails a check instead of hanging the harness.
private func eventually(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - P2. The store

@MainActor
private func checkNotebookStore() async {
    print("\n--- P2. the store ---")
    let sample = sampleNotebook()

    do {
        let directory = makeCacheDir()
        let store = storeIn(directory)
        let first = await store.load()
        await store.flush()
        let writes = await store.writeCount
        check("with nothing saved the store reads empty, and flushing nothing creates no file",
              first == .empty && names(in: directory).isEmpty && writes == 0, "\(first), \(names(in: directory))")
    }

    do {
        let directory = makeCacheDir()
        let writer = storeIn(directory)
        _ = await writer.load()
        await writer.save(sample)
        await writer.flush()
        let reader = storeIn(directory)
        let result = await reader.load()
        check("a flushed notebook is on disk at once, and a fresh store, as after a relaunch, reads it back equal",
              result == .loaded(sample, dropped: 0) && names(in: directory) == ["FieldNotebook.json"], "\(result)")
    }

    do {
        let directory = makeCacheDir()
        let store = storeIn(directory, delay: .milliseconds(400))
        _ = await store.load()
        let versions = (0..<50).map { FieldNotebook(items: [.trace(line(3, from: 38 + Double($0) * 0.01))]) }
        for version in versions { await store.save(version) }
        let early = exists(notebookFile(directory))
        let written = await eventually { exists(notebookFile(directory)) }
        try? await Task.sleep(for: .milliseconds(700))
        let writes = await store.writeCount
        check("nothing reaches the disk before the delay, and it does after it",
              !early && written, "early \(early), written \(written)")
        check("a burst of 50 saves is one write, and it holds the last of them",
              writes == 1 && readNotebook(notebookFile(directory)) == versions.last, "\(writes) writes")
    }

    do {
        let directory = makeCacheDir()
        let store = storeIn(directory, delay: .milliseconds(300))
        _ = await store.load()
        await store.save(sample)
        await store.flush()
        let now = exists(notebookFile(directory))
        try? await Task.sleep(for: .milliseconds(600))
        let writes = await store.writeCount
        await store.flush()
        let afterIdleFlush = await store.writeCount
        check("a flush writes at once and leaves nothing to write later; flushing again with nothing new writes nothing",
              now && writes == 1 && afterIdleFlush == 1, "now \(now), \(writes) writes, \(afterIdleFlush)")
    }

    do {
        let directory = makeCacheDir()
        let store = storeIn(directory)
        _ = await store.load()
        let older = FieldNotebook(items: [.trace(line(3))])
        await store.save(older)
        await store.save(sample)
        await store.flush()
        check("the newest notebook wins: a later save replaces an earlier one still waiting",
              readNotebook(notebookFile(directory)) == sample)
    }

    do {
        let directory = makeCacheDir()
        let deep = directory.appendingPathComponent("a").appendingPathComponent("b")
        let store = FieldNotebookStore(fileURL: deep.appendingPathComponent("FieldNotebook.json"), saveDelay: .milliseconds(50))
        _ = await store.load()
        await store.save(sample)
        await store.flush()
        check("a directory that is not there yet is made", readNotebook(deep.appendingPathComponent("FieldNotebook.json")) == sample)
    }

    do {
        let directory = makeCacheDir()
        let store = storeIn(directory, delay: .milliseconds(30))
        _ = await store.load()
        for _ in 0..<5 {
            await store.save(FieldNotebook(items: [.trace(line(3))]))
            await store.flush()
        }
        check("writes are atomic: nothing but the notebook is left in the directory",
              names(in: directory) == ["FieldNotebook.json"], "\(names(in: directory))")
    }

    // A write that fails is reported, keeps the notebook, and is retried.
    if runsAsRoot {
        print("  SKIP  a write that fails is kept and retried (running as root, where permissions do not block a write)")
    } else {
        let directory = makeCacheDir()
        let sub = directory.appendingPathComponent("locked")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let store = FieldNotebookStore(fileURL: sub.appendingPathComponent("FieldNotebook.json"), saveDelay: .milliseconds(50))
        _ = await store.load()
        setPermissions(sub, 0o555)
        await store.save(sample)
        await store.flush()
        let failedWrites = await store.writeCount
        let error = await store.lastWriteError
        setPermissions(sub, 0o755)
        await store.flush()
        let writes = await store.writeCount
        let after = await store.lastWriteError
        check("a write that fails is reported and does not lose the notebook, which is written when the next flush can",
              failedWrites == 0 && error != nil && writes == 1 && after == nil
              && readNotebook(sub.appendingPathComponent("FieldNotebook.json")) == sample,
              "\(failedWrites) writes, error \(String(describing: error)), then \(writes), \(String(describing: after))")
    }

    // A file that cannot be read as a notebook is set aside, whole, before anything can be written over it.
    let good = (try? sample.encoded()) ?? Data()
    let variants: [(String, Data)] = [
        ("garbage", Data((0..<200).map { UInt8(($0 * 13 + 5) & 0xff) })),
        ("empty", Data()),
        ("cut off", Data(good.prefix(good.count / 2))),
        ("an array", Data("[1,2,3]".utf8)),
        ("a later version", mutated(sample) { $0["version"] = 99 }),
    ]
    var problems: [String] = []
    for (label, bytes) in variants {
        let directory = makeCacheDir()
        let file = notebookFile(directory)
        try? bytes.write(to: file)
        let store = storeIn(directory, delay: .milliseconds(30))
        let result = await store.load()
        guard case .quarantined(_, let keptAt) = result else {
            problems.append("\(label): \(result)")
            continue
        }
        let kept = (try? Data(contentsOf: keptAt)) == bytes && keptAt.deletingLastPathComponent().path == directory.path
        let vacated = !exists(file)
        await store.save(sample)
        await store.flush()
        let fresh = readNotebook(file) == sample
        let untouched = (try? Data(contentsOf: keptAt)) == bytes
        if !(kept && vacated && fresh && untouched && names(in: directory).count == 2) {
            problems.append("\(label): kept \(kept) vacated \(vacated) fresh \(fresh) untouched \(untouched) \(names(in: directory))")
        }
    }
    check("a file that is not a notebook is moved aside with its bytes intact, and the notebook written afterwards leaves it alone (garbage, empty, cut off, an array, a later version)",
          problems.isEmpty, problems.joined(separator: "; "))

    // A file too big to read safely is set aside without being read: loading holds the file and what it decodes to at
    // once, so one that is many times the memory the app may use would be killed on launch, on every launch.
    do {
        let bytes = (try? sample.encoded()) ?? Data()
        let size = Int64(bytes.count)
        var results: [String] = []

        // At the cap it loads; one byte over, it is set aside intact.
        for (label, cap, expectLoaded) in [("at the cap", size, true), ("one byte over the cap", size - 1, false)] {
            let directory = makeCacheDir()
            let file = notebookFile(directory)
            try? bytes.write(to: file)
            let store = FieldNotebookStore(fileURL: file, saveDelay: .milliseconds(30), maxFileBytes: cap)
            let result = await store.load()
            switch (result, expectLoaded) {
            case (.loaded(let notebook, _), true):
                if notebook != sample { results.append("\(label): loaded a different notebook") }
            case (.quarantined(let reason, let keptAt), false):
                let intact = (try? Data(contentsOf: keptAt)) == bytes && !exists(file)
                let says = reason.contains("larger than")
                await store.save(sample)
                await store.flush()
                let fresh = readNotebook(file) == sample
                if !(intact && says && fresh) { results.append("\(label): intact \(intact), reason '\(reason)', a new notebook can be written \(fresh)") }
            default:
                results.append("\(label): \(result)")
            }
        }
        check("a file over the size the store will read is moved aside intact and says why, a file at that size loads, and a notebook can be written after",
              results.isEmpty, results.joined(separator: "; "))

        // The size decides before anything is read: garbage that is too big is refused for its size, not for not being a
        // notebook, which it could only be told by reading it.
        let directory = makeCacheDir()
        let file = notebookFile(directory)
        try? Data(repeating: 0x7B, count: 5_000).write(to: file)
        let store = FieldNotebookStore(fileURL: file, saveDelay: .milliseconds(30), maxFileBytes: 1_000)
        let refusal = await store.load()
        var reason = ""
        if case .quarantined(let text, _) = refusal { reason = text }
        check("the size is judged before the file is read: too big and not a notebook is refused for its size",
              reason.contains("larger than") && !reason.lowercased().contains("notebook"), "'\(reason)'")

        // The default limit stops a file far larger than memory without reading it: a sparse 3 GB file is set aside at once.
        let hugeDirectory = makeCacheDir()
        let huge = notebookFile(hugeDirectory)
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: huge) {
            try? handle.truncate(atOffset: 3 * 1024 * 1024 * 1024)
            try? handle.close()
        }
        let hugeStore = storeIn(hugeDirectory)
        let started = Date()
        let hugeResult = await hugeStore.load()
        let seconds = Date().timeIntervalSince(started)
        var hugeKept = false
        var hugeReason = ""
        if case .quarantined(let text, let keptAt) = hugeResult {
            hugeReason = text
            hugeKept = (try? keptAt.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == 3 * 1024 * 1024 * 1024 && !exists(huge)
        }
        check("a 3 GB file is set aside at once with the default limit, whole, without being read",
              hugeKept && hugeReason.contains("larger than") && seconds < 2, "kept \(hugeKept), '\(hugeReason)', \(String(format: "%.2f", seconds)) s")
    }

    do {
        let directory = makeCacheDir()
        let file = notebookFile(directory)
        let oneBad = mutated(sample) { root in
            var list = root["items"] as? [[String: Any]] ?? []
            list.append(["kind": "photo"])
            root["items"] = list
        }
        try? oneBad.write(to: file)
        let result = await storeIn(directory).load()
        check("a notebook with an item it cannot read loads what it can, says how many it left out, and is not set aside",
              result == .loaded(sample, dropped: 1) && names(in: directory) == ["FieldNotebook.json"], "\(result)")
    }

    do {
        let directory = makeCacheDir()
        let file = notebookFile(directory)
        try? good.write(to: file)
        let store = storeIn(directory, delay: .milliseconds(30))
        await store.save(FieldNotebook(items: [.trace(line(3))]))
        await store.flush()
        let writes = await store.writeCount
        let unchanged = (try? Data(contentsOf: file)) == good
        let loaded = await store.load()
        check("a store that has not yet read the file writes nothing over it, and reading it then gives the file as it was",
              writes == 0 && unchanged && loaded == .loaded(sample, dropped: 0), "\(writes) writes, unchanged \(unchanged)")
        await store.flush()
        check("what was saved before the file was read is discarded, not written over what was read",
              (try? Data(contentsOf: file)) == good)
    }

    if runsAsRoot {
        print("  SKIP  a file that cannot be read is neither replaced nor set aside (running as root)")
    } else {
        let directory = makeCacheDir()
        let file = notebookFile(directory)
        try? good.write(to: file)
        setPermissions(file, 0o000)
        let store = storeIn(directory, delay: .milliseconds(30))
        let result = await store.load()
        await store.save(FieldNotebook(items: [.trace(line(3))]))
        await store.flush()
        let writes = await store.writeCount
        setPermissions(file, 0o644)
        let intact = (try? Data(contentsOf: file)) == good && names(in: directory) == ["FieldNotebook.json"]
        let retry = await store.load()
        await store.save(sample)
        await store.flush()
        var isUnreadable = false
        if case .unreadable = result { isUnreadable = true }
        check("a file that cannot be read (locked, say) is neither replaced nor set aside, and once it can be read the store writes again",
              isUnreadable && writes == 0 && intact && retry == .loaded(sample, dropped: 0),
              "\(result), \(writes) writes, intact \(intact), retry \(retry)")
    }
}

// MARK: - P3. The model

private enum FlatMap {
    static func coordinate(_ p: CGPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 38.66 - Double(p.y) * 1e-5, longitude: -90.07 + Double(p.x) * 1e-5)
    }
}

@MainActor
private func makeModel(_ directory: URL, delay: Duration = .milliseconds(400)) -> TerrainViewerModel {
    let model = TerrainViewerModel(fieldNotebookStore: storeIn(directory, delay: delay))
    model.markupCoordinateConverter = FlatMap.coordinate
    return model
}

@MainActor
private func stroke(_ model: TerrainViewerModel, _ offset: Double = 0) {
    let points = (0..<20).map { CGPoint(x: 100 + Double($0) * 5 + offset, y: 300 + 20 * sin(Double($0) * 0.5) + offset) }
    model.addFieldTrace(screenPoints: points, colorHex: "#FF3B30", strokeWidth: 4)
}

private let pit = CLLocationCoordinate2D(latitude: 38.66, longitude: -90.06)

/// A store that keeps notebooks in memory and makes its first save slow, so that a save which does not wait for the one
/// before it arrives first and finishes first, and the notebook it leaves is not the newest.
private actor SlowFirstSaveStore: FieldNotebookPersisting {
    private(set) var arrived: [Int] = []
    private(set) var finished: [Int] = []
    private var saves = 0

    func load() async -> FieldNotebookStore.LoadResult { .empty }

    func save(_ notebook: FieldNotebook) async {
        saves += 1
        arrived.append(notebook.items.count)
        if saves == 1 { try? await Task.sleep(for: .milliseconds(200)) }
        finished.append(notebook.items.count)
    }

    func flush() async {}
}

@MainActor
private func checkNotebookSaveOrder() async {
    print("\n--- P5. saves reach the store in the order they were made ---")
    let store = SlowFirstSaveStore()
    let model = TerrainViewerModel(fieldNotebookStore: store)
    model.markupCoordinateConverter = FlatMap.coordinate
    await model.restoreFieldMarkup()
    for i in 0..<4 { stroke(model, Double(i) * 30) }
    await model.flushFieldMarkup()
    let arrived = await store.arrived
    let finished = await store.finished
    check("saves reach the store one after another in the order they were made, so the last notebook it holds is the newest even when an earlier save is slow",
          arrived == [1, 2, 3, 4] && finished == [1, 2, 3, 4], "arrived \(arrived), finished \(finished)")
}

/// Holds a caller until it is opened, and says when a caller has arrived.
private actor Latch {
    private var entered = false
    private var opened = false
    private var waiting: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func enterAndWait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}

@MainActor
private func checkNotebookModel() async {
    print("\n--- P3. the viewer model ---")

    // Drawn, flushed, relaunched.
    let directory = makeCacheDir()
    let first = makeModel(directory)
    await first.restoreFieldMarkup()
    stroke(first, 0)
    await first.addFieldWaypoint(at: pit, title: "Pit", notes: "looter?")
    stroke(first, 50)
    await first.flushFieldMarkup()

    let second = makeModel(directory)
    let versionBefore = second.markupVersion
    await second.restoreFieldMarkup()
    check("what was drawn is on disk after a flush, and a new model, as after a relaunch, restores every item and tells the map",
          second.fieldTraces.map(\.id) == first.fieldTraces.map(\.id) && second.fieldWaypoints.map(\.id) == first.fieldWaypoints.map(\.id)
          && second.fieldTraces.count == 2 && second.fieldWaypoints.count == 1 && second.hasRestoredFieldMarkup
          && second.markupVersion > versionBefore && second.markupNotice == nil,
          "\(second.fieldTraces.count) traces, \(second.fieldWaypoints.count) waypoints, version \(second.markupVersion)")
    let traceIDs = second.fieldTraces.map(\.id)
    second.undoFieldMarkup()
    check("undo after a relaunch takes back the newest item first, as it did before it: the last trace, then the waypoint",
          second.fieldTraces.map(\.id) == Array(traceIDs.prefix(1)) && traceIDs.count == 2 && second.fieldWaypoints.count == 1)
    await second.flushFieldMarkup()

    let third = makeModel(directory)
    await third.restoreFieldMarkup()
    let afterUndo = (third.fieldTraces.count, third.fieldWaypoints.count)
    let survivor = third.fieldTraces.first?.id
    third.clearFieldMarkup()
    await third.flushFieldMarkup()
    let fourth = makeModel(directory)
    await fourth.restoreFieldMarkup()
    check("an undo is saved: after it a relaunch shows what was left, one trace and the waypoint",
          afterUndo == (1, 1) && survivor != nil && survivor == traceIDs.first, "\(afterUndo)")
    check("a clear is saved: after it a relaunch shows nothing, and the file is an empty notebook",
          third.fieldTraces.isEmpty && !fourth.hasFieldMarkup && fourth.hasRestoredFieldMarkup
          && readNotebook(notebookFile(directory)) == FieldNotebook(),
          "\(fourth.fieldTraces.count) traces, \(fourth.fieldWaypoints.count) waypoints")

    // Restoring twice does not double the notebook.
    do {
        let directory = makeCacheDir()
        let writer = makeModel(directory)
        await writer.restoreFieldMarkup()
        stroke(writer)
        await writer.flushFieldMarkup()
        let reader = makeModel(directory)
        await reader.restoreFieldMarkup()
        await reader.restoreFieldMarkup()
        check("restoring again is harmless: the notebook is not read into the model twice",
              reader.fieldTraces.count == 1 && reader.hasRestoredFieldMarkup)
    }

    // A notebook nobody has touched is not written straight back: that would be a write on every launch.
    do {
        let directory = makeCacheDir()
        let seed = storeIn(directory)
        _ = await seed.load()
        await seed.save(sampleNotebook())
        await seed.flush()
        let store = storeIn(directory, delay: .milliseconds(50))
        let model = TerrainViewerModel(fieldNotebookStore: store)
        await model.restoreFieldMarkup()
        try? await Task.sleep(for: .milliseconds(400))
        let writes = await store.writeCount
        check("restoring a saved notebook that nothing has been drawn over does not write it straight back",
              writes == 0 && model.fieldTraces.count == 2 && model.fieldWaypoints.count == 2 && model.hasRestoredFieldMarkup,
              "\(writes) writes, \(model.fieldTraces.count) traces")
    }

    // Drawing before the saved notebook has been read must not overwrite it.
    do {
        let directory = makeCacheDir()
        let seed = storeIn(directory)
        let sample = sampleNotebook()
        _ = await seed.load()
        await seed.save(sample)
        await seed.flush()

        let model = makeModel(directory)
        stroke(model)                                   // drawn before the saved notebook is read
        await model.flushFieldMarkup()
        let untouched = readNotebook(notebookFile(directory)) == sample
        await model.restoreFieldMarkup()
        await model.flushFieldMarkup()
        let merged = readNotebook(notebookFile(directory))
        var lastIsNew = false
        if case .trace(let trace)? = merged?.items.last { lastIsNew = trace.id == model.fieldTraces.last?.id }
        check("a stroke drawn before the saved notebook has been read does not overwrite it, and joins it, last, once it has",
              untouched && merged?.items.count == 5 && merged.map({ Array($0.items.prefix(4)) }) == sample.items && lastIsNew
              && model.fieldTraces.count == 3 && model.fieldWaypoints.count == 2,
              "untouched \(untouched), \(String(describing: merged?.items.count)) items")
    }

    // A damaged file.
    do {
        let directory = makeCacheDir()
        try? Data("{ this is not a notebook".utf8).write(to: notebookFile(directory))
        let model = makeModel(directory)
        await model.restoreFieldMarkup()
        let notice = model.markupNotice ?? ""
        let keptName = names(in: directory).first { $0 != "FieldNotebook.json" } ?? ""
        stroke(model)
        await model.flushFieldMarkup()
        check("a damaged file is set aside, the user is told where it went, and drawing carries on into a fresh file",
              !keptName.isEmpty && notice.contains(keptName) && notice.lowercased().contains("could not be read")
              && model.hasFieldMarkup && model.hasRestoredFieldMarkup
              && readNotebook(notebookFile(directory))?.traces.count == 1 && names(in: directory).count == 2,
              "notice '\(notice)', files \(names(in: directory))")
    }

    // A file that cannot be read yet.
    if runsAsRoot {
        print("  SKIP  a notebook that cannot be read yet is not overwritten (running as root)")
    } else {
        let directory = makeCacheDir()
        let sample = sampleNotebook()
        let seed = storeIn(directory)
        _ = await seed.load()
        await seed.save(sample)
        await seed.flush()
        let original = try? Data(contentsOf: notebookFile(directory))
        setPermissions(notebookFile(directory), 0o000)

        let model = makeModel(directory)
        await model.restoreFieldMarkup()
        let heldBack = !model.hasRestoredFieldMarkup
        stroke(model)
        await model.flushFieldMarkup()
        setPermissions(notebookFile(directory), 0o644)
        let intact = (try? Data(contentsOf: notebookFile(directory))) == original
        await model.restoreFieldMarkup()
        await model.flushFieldMarkup()
        check("a notebook that cannot be read yet is not overwritten by what is drawn meanwhile; when it can be read the two are joined and kept",
              heldBack && intact && model.hasRestoredFieldMarkup && readNotebook(notebookFile(directory))?.items.count == 5
              && model.fieldTraces.count == 3,
              "held back \(heldBack), intact \(intact), \(String(describing: readNotebook(notebookFile(directory))?.items.count)) items")
    }

    // Clear while a waypoint's terrain lookup is still running: held open by a latch, so the order is not left to
    // the scheduler.
    do {
        let directory = makeCacheDir()
        let model = makeModel(directory)
        await model.restoreFieldMarkup()
        stroke(model)
        let latch = Latch()
        model.markupElevationLookup = { _ in
            await latch.enterAndWait()
            return 100
        }
        let marking = Task { await model.addFieldWaypoint(at: pit, title: "Late", notes: "") }
        let lookupBegun = await eventually { await latch.hasEntered }
        model.clearFieldMarkup()
        await latch.open()
        await marking.value
        check("a waypoint whose terrain lookup is still running when Clear is tapped does not reappear after it",
              lookupBegun && !model.hasFieldMarkup && model.fieldWaypoints.isEmpty,
              "begun \(lookupBegun), \(model.fieldTraces.count) traces, \(model.fieldWaypoints.count) waypoints")

        // And the same lookup, undisturbed, lands with the height it read.
        let undisturbed = Task { await model.addFieldWaypoint(at: pit, title: "On time", notes: "") }
        await undisturbed.value
        check("a waypoint whose lookup is not disturbed is added with the height it read",
              model.fieldWaypoints.count == 1 && model.fieldWaypoints.first?.elevationMeters == 100)
    }

    // A model that keeps nothing.
    do {
        let plain = TerrainViewerModel()
        plain.markupCoordinateConverter = FlatMap.coordinate
        await plain.restoreFieldMarkup()
        stroke(plain)
        await plain.flushFieldMarkup()
        check("a model with no store draws as before, and restoring and flushing it are harmless",
              plain.fieldTraces.count == 1 && plain.markupNotice == nil && !plain.hasRestoredFieldMarkup)
    }
}

// MARK: - P4. Random sequences

/// A deterministic generator, so a failing sequence can be replayed from its seed.
private struct SequenceRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}

/// Many random runs of drawing, undoing, clearing, flushing and relaunching, each checked against a plain list.
///
/// After a relaunch that followed a flush the notebook must be exactly what was there; after a kill (the file as it
/// stood, copied to a fresh place) it must be one of the states the notebook passed through since the last flush, never
/// a mixture, never a state from before it.
@MainActor
private func checkNotebookFuzz() async {
    print("\n--- P4. random sequences against a plain list ---")
    var problems: [String] = []
    var relaunches = 0, kills = 0, operations = 0
    for seed in 1...40 {
        var rng = SequenceRNG(state: UInt64(seed) * 7919)
        var directory = makeCacheDir()
        var model = makeModel(directory, delay: .milliseconds(15))
        await model.restoreFieldMarkup()
        var history: [[UUID]] = [[]]                 // the notebook's states, oldest first, by item order
        var flushed = 0                              // the index in `history` that a flush last made durable
        func current() -> [UUID] { model.notebookOrderForChecks }
        for _ in 0..<40 {
            operations += 1
            switch rng.below(10) {
            case 0, 1, 2:
                stroke(model, Double(rng.below(200)))
                history.append(current())
            case 3, 4:
                await model.addFieldWaypoint(at: CLLocationCoordinate2D(latitude: 38.6 + Double(rng.below(100)) * 1e-4, longitude: -90.06), title: "w\(rng.below(1000))")
                history.append(current())
            case 5:
                model.undoFieldMarkup()
                history.append(current())
            case 6:
                if rng.below(4) == 0 { model.clearFieldMarkup(); history.append(current()) }
            case 7:
                try? await Task.sleep(for: .milliseconds(rng.below(40)))
            case 8:
                await model.flushFieldMarkup()
                flushed = history.count - 1
            default:
                relaunches += 1
                if rng.below(3) == 0 {
                    // A kill: whatever is on disk now, copied to a fresh place, is all the next launch has.
                    kills += 1
                    let survivor = makeCacheDir()
                    if let data = try? Data(contentsOf: notebookFile(directory)) { try? data.write(to: notebookFile(survivor)) }
                    let allowed = Array(history[flushed...])
                    directory = survivor
                    model = makeModel(directory, delay: .milliseconds(15))
                    await model.restoreFieldMarkup()
                    let restored = current()
                    if !allowed.contains(restored) && !(flushed == 0 && restored.isEmpty) {
                        problems.append("seed \(seed): after a kill the notebook held \(restored.count) items, matching none of the \(allowed.count) states since the last flush")
                    }
                    history = [restored]
                    flushed = 0
                } else {
                    // A graceful relaunch: flushed first, then read back exactly.
                    await model.flushFieldMarkup()
                    let expected = current()
                    model = makeModel(directory, delay: .milliseconds(15))
                    if rng.below(3) == 0 {
                        // Draw before the saved notebook has been read: it joins it, last.
                        stroke(model, 5)
                        let drawn = model.notebookOrderForChecks
                        await model.restoreFieldMarkup()
                        let restored = current()
                        if restored != expected + drawn {
                            problems.append("seed \(seed): a stroke drawn before the read did not join the saved notebook last (\(restored.count) vs \(expected.count + drawn.count))")
                        }
                    } else {
                        await model.restoreFieldMarkup()
                        if current() != expected {
                            problems.append("seed \(seed): a flushed notebook came back as \(current().count) items, not \(expected.count)")
                        }
                    }
                    history = [current()]
                    flushed = 0
                }
            }
            if problems.count > 5 { break }
        }
        await model.flushFieldMarkup()
        if problems.count > 5 { break }
    }
    check("40 random runs of \(operations) operations, \(relaunches) relaunches (\(kills) of them kills): a flushed notebook always comes back exactly, a killed one is always a state it passed through, and a stroke drawn before the read joins it last",
          problems.isEmpty, problems.prefix(5).joined(separator: "; "))
}
