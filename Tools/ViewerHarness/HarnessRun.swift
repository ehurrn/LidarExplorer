//
//  HarnessRun.swift
//  ViewerHarness
//
//  What one run of the harness keeps to itself, so that runs side by side -- in two worktrees, or two in the
//  same one -- never read or delete each other's files.
//
//  Tools/run-harness.sh gives each run a directory of its own and runs the harness inside it: its home
//  (CFFIXED_USER_HOME, which moves Caches, Application Support and Documents), its temporary files
//  (HARNESS_TMPDIR, below) and its working directory, where URLCache keeps a relative disk path. The binary is
//  copied there under a name of its own, which gives the run a UserDefaults domain of its own, since a tool
//  with no bundle takes its domain from its executable's name.
//

import Foundation

/// Where this run keeps its temporary files: `HARNESS_TMPDIR`, set by Tools/run-harness.sh to a directory the
/// run owns and removes when it ends. Run by hand without it, a directory of the run's own under the system's.
nonisolated let harnessTemporaryDirectory: URL = {
    let url: URL
    if let given = ProcessInfo.processInfo.environment["HARNESS_TMPDIR"], !given.isEmpty {
        url = URL(fileURLWithPath: given, isDirectory: true)
    } else {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LidarExplorerHarness-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

// MARK: - HARNESS_ONLY: a partial run

/// Which sections this run runs: all of them, unless `HARNESS_ONLY` names some.
///
/// `HARNESS_ONLY` is a comma-separated list, and each item picks every section it matches:
/// - a subsection's code as its header prints it, whole and ignoring case: `B12` for `--- B12. ...`;
/// - or, three letters or more, part of a section's file name (`ProviderMicro`) or title (`harvester`).
/// The sections are the files beside main.swift with a `===` header, read from the sources themselves, so the
/// headers are the only index. main.swift's own sections are one, `core`: picked by that word or by any of
/// their titles, and otherwise skipped. An item that matches nothing ends the run before it starts (exit 2).
struct HarnessSelection {
    /// A file of checks, as its headers name it.
    struct Section {
        let file: String
        let titles: [String]
        let codes: [String]
    }

    /// The items of `HARNESS_ONLY`, or nil for a full run.
    let items: [String]?
    /// The files picked, by name without `.swift`; `main` for the core.
    let files: Set<String>

    var isPartial: Bool { items != nil }
    var runsCore: Bool { !isPartial || files.contains("main") }
    func runs(_ file: String) -> Bool { !isPartial || files.contains(file) }

    static func fromEnvironment() -> HarnessSelection {
        let raw = ProcessInfo.processInfo.environment["HARNESS_ONLY"] ?? ""
        let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return HarnessSelection(items: nil, files: []) }
        let sections = readSections()
        var files: Set<String> = []
        var unmatched: [String] = []
        print("\n=== PARTIAL RUN: HARNESS_ONLY=\(raw) ===")
        for item in items {
            let key = item.lowercased()
            let hits = sections.filter { section in
                (section.file == "main" && (key == "core" || key == "main"))
                    || section.codes.contains { $0.lowercased() == key }
                    || (key.count >= 3 && (section.file.lowercased().contains(key)
                        || section.titles.contains { $0.lowercased().contains(key) }))
            }
            if hits.isEmpty { unmatched.append(item) }
            files.formUnion(hits.map(\.file))
            print("  \(item) -> \(hits.isEmpty ? "nothing" : hits.map { $0.file == "main" ? "core (main.swift)" : "\($0.file).swift" }.joined(separator: ", "))")
        }
        if !unmatched.isEmpty {
            let codes = Set(sections.flatMap(\.codes)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            print("HARNESS_ONLY: nothing matches \(unmatched.joined(separator: ", ")). An item is \"core\", three letters or more "
                  + "of a check file's name or a section's title, or a subsection code: \(codes.joined(separator: " "))")
            exit(2)
        }
        let skipped = sections.filter { !files.contains($0.file) }.count
        print("  runs \(files.count) of \(sections.count) sections (main.swift's own count as one, \"core\"); "
              + "skips \(skipped). Unset HARNESS_ONLY for the full run.")
        return HarnessSelection(items: items, files: files)
    }

    /// The check files beside this one, with the titles and subsection codes their headers print.
    private static func readSections() -> [Section] {
        let this = URL(fileURLWithPath: #filePath)
        let directory = this.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // Not this file, whose own code spells out the headers it looks for.
        return names.filter { $0.hasSuffix(".swift") && $0 != this.lastPathComponent }.sorted().compactMap { name in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { return nil }
            var titles: [String] = [], codes: [String] = []
            for line in text.split(separator: "\n") {
                if let start = line.range(of: #"print("\n=== "#), let end = line[start.upperBound...].range(of: " ===") {
                    titles.append(String(line[start.upperBound..<end.lowerBound]))
                }
                if let start = line.range(of: #"print("\n--- "#), let end = line[start.upperBound...].range(of: ". ") {
                    let code = line[start.upperBound..<end.lowerBound]
                    if code.count <= 6 && !code.contains(" ") { codes.append(String(code)) }
                }
            }
            guard !titles.isEmpty else { return nil }
            return Section(file: String(name.dropLast(".swift".count)), titles: titles, codes: codes)
        }
    }
}

/// This run's selection. Read on first use, at the top of main.swift, so a filter that matches nothing stops
/// the run before any check.
let harnessSelection = HarnessSelection.fromEnvironment()

/// The section files that have run, so a partial run can tell a picked file main.swift never ran.
var harnessSectionsRun: Set<String> = []

/// Runs the section in `file` (its name without `.swift`) unless HARNESS_ONLY leaves it out.
func harnessSection(_ file: String, _ body: () async -> Void) async {
    guard harnessSelection.runs(file) else { return }
    harnessSectionsRun.insert(file)
    await body()
}

// MARK: - The system's temporary directory

/// Runs `body` while no other harness run on this Mac is inside such a block.
///
/// For what the app writes where a run cannot move it: the model exports to the system's temporary directory
/// (`FileManager.default.temporaryDirectory`, which on macOS ignores `TMPDIR`) under names that differ only by
/// the second, so two runs exporting in the same second would write, read and delete the same file. The lock
/// is the kernel's (flock), so a run that dies releases it, and it is polled rather than waited on, so the main
/// actor keeps running while another run finishes its exports.
@MainActor
func withSystemTemporaryDirectoryLock(_ body: () async -> Void) async {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("LidarExplorerHarness.exports.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else {
        print("        (no lock on \(path): exporting without one)")
        await body()
        return
    }
    defer { close(descriptor) }
    var announced = false
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        if !announced {
            print("        (waiting for another harness run to finish exporting)")
            announced = true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    await body()
    flock(descriptor, LOCK_UN)
}
