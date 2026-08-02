// Opt-in capture recorder for diagnosing transcription failures.
//
// Saves each dictation's captured PCM as a WAV under
// ~/Library/Logs/TypeWiser/captures/ so the exact audio handed to the
// recognizer can be replayed offline. This is the only way to tell a
// "recognizer misbehaved" failure apart from a "the mic captured loud but
// unintelligible audio" one — amplitude alone cannot distinguish them, as a
// 2026-08-02 investigation found the hard way: every logged metric looked
// healthy while the audio was in fact untranscribable.
//
// PRIVACY: these files ARE the user's speech. Nothing enables this
// automatically; the directory must be created by hand, and it is never
// created for you. Absent it, this is a cheap `fileExists` and nothing else.
//
//   mkdir -p ~/Library/Logs/TypeWiser/captures
import Foundation

public enum CaptureDump {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TypeWiser/captures", isDirectory: true)
    }

    public static func saveIfEnabled(_ pcm16: [Int16]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else { return }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("capture-\(stamp).wav")
        do {
            try WAVEncoder.encode(pcm16: pcm16).write(to: url, options: .atomic)
            TWLog.audio.info("capture saved: \(url.lastPathComponent, privacy: .public)")
        } catch {
            TWLog.audio.error("capture save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
