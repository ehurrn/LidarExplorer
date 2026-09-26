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
