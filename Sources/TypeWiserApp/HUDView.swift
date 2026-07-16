import SwiftUI
import TypeWiserCore

struct HUDView: View {
    @Bindable var state: HUDState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(body_)
                .font(.system(size: 14))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = state.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }

    private var label: String {
        switch state.phase {
        case .idle: return "Idle"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing…"
        case .rewriting: return "Cleaning up…"
        case .inserted: return "Inserted"
        case .error: return "Error"
        }
    }

    private var body_: String {
        switch state.phase {
        case .idle: return ""
        case .recording(let interim):
            // Interim trails ~3.5s behind speech: the server has one slot and a
            // fixed ~3.5s latency. Say so rather than looking broken.
            return interim.isEmpty ? "Listening… (text appears after ~3.5s)" : interim
        case .transcribing: return "Sending to Whisper…"
        case .rewriting: return "Polishing…"
        case .inserted(let t): return t
        case .error(let e): return e
        }
    }

    private var indicatorColor: Color {
        switch state.phase {
        case .recording: return .red
        case .transcribing, .rewriting: return .orange
        case .inserted: return .green
        case .error: return .red
        case .idle: return .secondary
        }
    }
}
