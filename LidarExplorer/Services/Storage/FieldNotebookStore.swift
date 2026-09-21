//
//  FieldNotebookStore.swift
//  LidarExplorer
//
//  Keeps the field notebook on disk without ever losing what is already there.
//
//  Three rules carry that:
//  - The store writes nothing until it has read the file (or found there is none), because a notebook made without
//    knowing what was saved would replace it.
//  - A file that cannot be read as a notebook is moved aside whole before anything is written, so a bug, a bad disk
//    or a later version's file costs the user nothing they cannot get back.
//  - A file that cannot be read for now (an iPad locked since it restarted, say) is left exactly as it is, and
//    nothing is written until it can be read.
//
//  Writes are coalesced: the first save opens a short window and the newest notebook at its close is what is
//  written, atomically, so a burst of strokes is one write and a crash mid-write leaves the old file or the new,
//  never half of one. Encoding and disk work happen on this actor, off the main actor.
//

import Foundation
import os

public actor FieldNotebookStore {

    public enum LoadResult: Sendable, Equatable {
        /// There was no file: nothing has been saved yet.
        case empty
        /// The notebook, and how many of its items could not be kept.
        case loaded(FieldNotebook, dropped: Int)
        /// The file was not a notebook this build can read. It was moved to `keptAt`, untouched, and the notebook
        /// starts empty.
        case quarantined(reason: String, keptAt: URL)
        /// The file could not be read (or moved aside). It was left alone and nothing will be written until a
        /// later ``load()`` succeeds.
        case unreadable(reason: String)
    }

    public nonisolated let fileURL: URL
    private let saveDelay: Duration

    /// The newest notebook not yet written.
    private var pending: FieldNotebook?
    private var timer: Task<Void, Never>?
    /// Whether the file on disk has been read and is safe to replace.
    private var canWrite = false

    /// Writes completed, for the harness and diagnostics.
    public private(set) var writeCount = 0
    /// Why the last write failed; nil when it succeeded or none has been tried.
    public private(set) var lastWriteError: String?

    public init(fileURL: URL, saveDelay: Duration = .milliseconds(500)) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
    }

    /// `FieldNotebook.json` in the app's Documents folder.
    public static func standard() -> FieldNotebookStore {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var delay = Duration.milliseconds(500)
        #if DEBUG
        // Lets a Simulator run stretch the coalescing window, to show that going to the background writes what is waiting.
        if let text = ProcessInfo.processInfo.environment["FIELD_NOTEBOOK_SAVE_DELAY_MS"], let milliseconds = Int(text) {
            delay = .milliseconds(milliseconds)
        }
        #endif
        return FieldNotebookStore(fileURL: directory.appendingPathComponent("FieldNotebook.json"), saveDelay: delay)
    }

    // MARK: - Reading

    /// Reads the saved notebook, and so allows writing unless the file could not be read.
    ///
    /// Anything waiting to be written is discarded: it was made without knowing what is on disk, and the caller
    /// saves the notebook it has joined to what was read.
    public func load() -> LoadResult {
        timer?.cancel()
        timer = nil
        pending = nil

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            canWrite = true
            return .empty
        } catch {
            canWrite = false
            Log.storage.error("Field notebook could not be read: \(error.localizedDescription, privacy: .public)")
            return .unreadable(reason: error.localizedDescription)
        }

        do {
            let decoded = try FieldNotebook.decode(data)
            canWrite = true
            if decoded.dropped > 0 {
                Log.storage.warning("Field notebook: \(decoded.dropped) items could not be kept")
            }
            return .loaded(decoded.notebook, dropped: decoded.dropped)
        } catch {
            let reason = Self.reason(for: error)
            guard let keptAt = setAside() else {
                canWrite = false
                Log.storage.error("Field notebook is unreadable (\(reason, privacy: .public)) and could not be moved aside")
                return .unreadable(reason: "\(reason), and it could not be moved aside")
            }
            canWrite = true
            Log.storage.error("Field notebook is unreadable (\(reason, privacy: .public)); kept as \(keptAt.lastPathComponent, privacy: .public)")
            return .quarantined(reason: reason, keptAt: keptAt)
        }
    }

    private static func reason(for error: any Error) -> String {
        switch error as? FieldNotebook.DecodeError {
        case .unsupportedVersion(let version)?: "it was saved by a newer version of the app, format \(version)"
        case .notANotebook(let detail)?: "\(detail)"
        case nil: error.localizedDescription
        }
    }

    /// Moves the file to a name of its own beside it, or returns nil if that could not be done.
    private func setAside() -> URL? {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "" : "." + fileURL.pathExtension
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        for attempt in 0..<100 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let candidate = directory.appendingPathComponent("\(base).damaged-\(stamp)\(suffix)\(ext)")
            guard !manager.fileExists(atPath: candidate.path) else { continue }
            do {
                try manager.moveItem(at: fileURL, to: candidate)
                return candidate
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: - Writing

    /// Offers the newest notebook. It is written when the coalescing window that this opens (if none is open)
    /// closes, and a save that arrives inside the window replaces the one waiting.
    public func save(_ notebook: FieldNotebook) {
        pending = notebook
        guard timer == nil else { return }
        let delay = saveDelay
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.windowClosed()
        }
    }

    /// Writes what is waiting now, for a caller about to lose the process (the app going to the background).
    /// Returns when the write has been made or has failed; ``lastWriteError`` says which.
    public func flush() {
        Log.storage.debug("Field notebook flush requested: \(self.pending == nil ? "nothing is waiting" : "a notebook is waiting")")
        timer?.cancel()
        timer = nil
        writePending()
    }

    private func windowClosed() {
        timer = nil
        writePending()
    }

    private func writePending() {
        guard let notebook = pending else { return }
        guard canWrite else {
            Log.storage.warning("Field notebook held back: the saved file has not been read yet")
            return
        }
        do {
            let data = try notebook.encoded()
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            pending = nil
            writeCount += 1
            lastWriteError = nil
            Log.storage.debug("Field notebook written: \(notebook.items.count) items, \(data.count) bytes")
        } catch {
            // The notebook stays pending: the next flush retries it.
            lastWriteError = error.localizedDescription
            Log.storage.error("Field notebook could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
