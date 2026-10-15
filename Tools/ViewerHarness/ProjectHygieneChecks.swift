//
//  ProjectHygieneChecks.swift
//  ViewerHarness
//
//  What the repository has to keep straight for a build to ship: the privacy manifest's required-reason API
//  declarations against the APIs the sources call, the project file's references against the files on disk, and
//  the two host-compiled tools sharing one list of sources.
//

import Foundation

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
func runProjectHygieneChecks() {
    print("\n=== Project hygiene ===")
    checkPrivacyManifest()
    checkProjectReferences()
    checkToolsShareSources()
}

private func swiftSources(under directory: URL) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

/// App Store Connect refuses a build that calls a required-reason API its privacy manifest does not declare
/// (ITMS-91053). Each category is matched by the API names Apple lists for it.
@MainActor
private func checkPrivacyManifest() {
    print("\n--- Z1. the privacy manifest declares the required-reason APIs the code calls ---")
    let manifest = repositoryRoot.appendingPathComponent("Config/PrivacyInfo.xcprivacy")
    guard let data = try? Data(contentsOf: manifest),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let types = plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] else {
        check("the privacy manifest is a plist with NSPrivacyAccessedAPITypes", false)
        return
    }
    var declared: [String: [String]] = [:]
    for type in types {
        guard let name = type["NSPrivacyAccessedAPIType"] as? String else { continue }
        declared[name] = type["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
    }
    let allowedReasons: [String: Set<String>] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1", "3D61.1"],
        "NSPrivacyAccessedAPICategoryDiskSpace": ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["3EC4.1", "54BD.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"],
    ]
    let sources = swiftSources(under: repositoryRoot.appendingPathComponent("LidarExplorer"))
    let texts = sources.map { ($0.lastPathComponent, (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
    let families: [(category: String, apis: [String])] = [
        ("NSPrivacyAccessedAPICategorySystemBootTime", ["systemUptime", "mach_absolute_time"]),
        ("NSPrivacyAccessedAPICategoryDiskSpace", ["volumeAvailableCapacity", "systemFreeSize", "statfs(", "statvfs(", "fstatfs("]),
        ("NSPrivacyAccessedAPICategoryFileTimestamp", ["creationDateKey", "contentModificationDateKey", ".creationDate", ".modificationDate", "fileModificationDate", "fstat(", "lstat(", "getattrlist("]),
        ("NSPrivacyAccessedAPICategoryUserDefaults", ["UserDefaults"]),
    ]
    for (category, apis) in families {
        let callers = texts.filter { text in apis.contains { text.1.contains($0) } }.map(\.0).sorted()
        let reasons = declared[category] ?? []
        let short = category.replacingOccurrences(of: "NSPrivacyAccessedAPICategory", with: "")
        check("\(short): called by \(callers.isEmpty ? "no file" : callers.joined(separator: ", ")), so \(callers.isEmpty ? "no declaration is needed" : "declared with a reason")",
              callers.isEmpty || !reasons.isEmpty, "declared reasons \(reasons)")
    }
    let badReasons = declared.flatMap { category, reasons in
        reasons.filter { !(allowedReasons[category] ?? []).contains($0) }.map { "\(category): \($0)" }
    }
    check("every declared reason is one Apple lists for its category", badReasons.isEmpty, "\(badReasons)")
}

/// A PBXFileReference to a file that is not there shows red in Xcode's navigator and, in a resource phase,
/// breaks the build.
@MainActor
private func checkProjectReferences() {
    print("\n--- Z2. the project file refers to files that exist ---")
    let project = repositoryRoot.appendingPathComponent("LidarExplorer.xcodeproj/project.pbxproj")
    guard let text = try? String(contentsOf: project, encoding: .utf8) else {
        check("the project file reads", false)
        return
    }
    // Group-relative references at the project's root group, which is the repository root here.
    let pattern = #"isa = PBXFileReference;[^\n]*? path = "?([^";]+)"?;[^\n]*sourceTree = "<group>";"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let paths = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
        Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
    let missing = paths.filter { !FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent($0).path) }
    check("every group-relative file reference (\(paths.count)) names a file or folder on disk", !paths.isEmpty && missing.isEmpty, "missing \(missing)")
}

/// The harness and the live check compile the app's host-compilable sources from one list, so a file added to
/// one cannot be left out of the other, and both build inside the repository.
@MainActor
private func checkToolsShareSources() {
    print("\n--- Z3. the harness and the live check share one list of sources ---")
    let tools = repositoryRoot.appendingPathComponent("Tools")
    let shared = (try? String(contentsOf: tools.appendingPathComponent("harness-sources.sh"), encoding: .utf8)) ?? ""
    let harness = (try? String(contentsOf: tools.appendingPathComponent("run-harness.sh"), encoding: .utf8)) ?? ""
    let live = (try? String(contentsOf: tools.appendingPathComponent("run-live-check.sh"), encoding: .utf8)) ?? ""
    check("both scripts source Tools/harness-sources.sh, which lists the app sources and the flags",
          shared.contains("APP_SOURCES=(") && shared.contains("SWIFT_FLAGS=(")
            && harness.contains(". Tools/harness-sources.sh") && live.contains(". Tools/harness-sources.sh"))
    let listed = shared.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " \\", with: "") }
        .filter { $0.hasPrefix("LidarExplorer/") }
    let missing = listed.filter { !FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent($0).path) }
    check("every source the shared list names exists (\(listed.count) files)", listed.count > 50 && missing.isEmpty, "missing \(missing)")
    check("the live check builds in build-review, inside the repository, and can stop after compiling",
          live.contains("build-review/live-check") && live.contains("LIVE_CHECK_BUILD_ONLY") && !live.contains("mktemp"))
}
