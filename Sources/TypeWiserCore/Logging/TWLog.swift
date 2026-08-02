import Foundation
import os

/// Central loggers, one per subsystem area. Everything goes through the macOS
/// unified log, so entries persist without any file management and are
/// queryable after the fact:
///
///     log show --last 1h --predicate 'subsystem == "xyz.crevn.typewiser"'
///
/// (or stream live with `log stream --predicate ...`, or filter in Console.app).
///
/// PRIVACY RULE: never log what the user said. No transcripts, no interim
/// results, no rewritten text, no AX-captured context — log lengths and error
/// details instead. Paths, states, and error descriptions are marked
/// `.public` deliberately: they are the debugging payload and contain no
/// speech. Anything derived from user audio must never appear in a log call.
public enum TWLog {
    public static let subsystem = "xyz.crevn.typewiser"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let stt = Logger(subsystem: subsystem, category: "stt")
    public static let rewrite = Logger(subsystem: subsystem, category: "rewrite")
}

/// The llama-server child is the one component whose diagnostics do NOT flow
/// through the unified log — it is a foreign process that prints to stderr.
/// This owns the file that output is redirected into, replacing the old
/// `FileHandle.nullDevice` sink that silently discarded engine failures
/// (model load errors, Metal init failures, port conflicts…).
public enum EngineLogFile {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TypeWiser", isDirectory: true)
    }

    public static var url: URL { directory.appendingPathComponent("engine.log") }

    /// One rotation generation is enough: `engine.log` + `engine.log.1` bounds
    /// disk use at ~2×`maxBytes` while always preserving the previous run's
    /// tail, which is what post-mortem debugging actually needs.
    static let maxBytes = 5 * 1024 * 1024

    /// Returns a handle positioned at end-of-file for appending, rotating
    /// first if the file has outgrown `maxBytes`. Returns nil (caller falls
    /// back to discarding, as before) only if the directory or file cannot be
    /// created — logging must never be the reason the engine fails to start.
    public static func handleForAppending() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > maxBytes {
            let rotated = directory.appendingPathComponent("engine.log.1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    /// Stamps a header so interleaved runs in the same file are separable.
    public static func writeSessionHeader(to handle: FileHandle, arguments: [String]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = "\n===== TypeWiser engine start \(stamp) =====\n$ \(arguments.joined(separator: " "))\n"
        try? handle.write(contentsOf: Data(header.utf8))
    }
}
