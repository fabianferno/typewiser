import SwiftUI
import TypeWiserCore

/// Zinc scale (Tailwind's), so the HUD's greys are a deliberate ramp rather
/// than a handful of unrelated `.gray` opacities.
enum Zinc {
    static let z100 = Color(red: 0.957, green: 0.957, blue: 0.965)
    static let z300 = Color(red: 0.831, green: 0.831, blue: 0.847)
    static let z400 = Color(red: 0.631, green: 0.631, blue: 0.667)
    static let z500 = Color(red: 0.443, green: 0.443, blue: 0.478)
    static let z800 = Color(red: 0.153, green: 0.153, blue: 0.165)
}

/// Fixed panel geometry. The panel is a constant-size, bottom-centred *stage*
/// that the card sits on, rather than a window sized to its content.
///
/// This is load-bearing for stability, not just tidiness. The card's height
/// swings from 89pt (a short "Inserted") to 201pt (recording with a three-line
/// interim plus the credentials note), measured across every phase. A window
/// sized to fit would therefore change height on nearly every phase change,
/// and AppKit keeps the *top-left* fixed when a window resizes — so the card's
/// bottom edge, the thing the user actually looks at, would jump between
/// phases. A window that never resizes cannot move.
///
/// `panelHeight` must exceed the tallest card (201pt) with headroom for larger
/// system font sizes; the surplus is transparent and click-through, so it
/// costs nothing visually.
enum HUDMetrics {
    static let cardWidth: CGFloat = 380

    static let shadowRadius: CGFloat = 20
    static let shadowOffsetY: CGFloat = 8

    /// Transparent margin around the card, and the reason it is this large:
    /// the panel's bounds clip anything drawn outside them, so an inset
    /// smaller than the shadow's reach cuts the shadow off mid-fade and leaves
    /// a hard rectangular edge around the card — a visible box on screen. It
    /// must therefore exceed `shadowRadius + shadowOffsetY`. The surplus is
    /// transparent and click-through, so being generous costs nothing.
    static let shadowInset: CGFloat = shadowRadius + shadowOffsetY + 4

    static let panelWidth: CGFloat = cardWidth + shadowInset * 2
    /// Must clear the tallest card (181pt of content, measured across every
    /// phase) plus both insets, with headroom for larger system font sizes.
    static let panelHeight: CGFloat = 300

    /// Gap from the bottom of the screen's visible frame to the card itself
    /// (not to the panel — `HUDController.reposition` subtracts the inset).
    static let bottomMargin: CGFloat = 44
}

struct HUDView: View {
    @Bindable var state: HUDState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            card
        }
        .frame(width: HUDMetrics.panelWidth,
               height: HUDMetrics.panelHeight,
               alignment: .bottom)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Zinc.z400)
                Spacer()
            }

            if showsWaveform {
                WaveformView(levels: state.levels, tint: waveformTint)
            }

            if !body_.isEmpty {
                Text(body_)
                    .font(.system(size: 14))
                    .foregroundStyle(Zinc.z100)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let note = state.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: HUDMetrics.cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Zinc.z800, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5),
                radius: HUDMetrics.shadowRadius,
                y: HUDMetrics.shadowOffsetY)
        .padding(HUDMetrics.shadowInset)
    }

    /// Kept up through transcribing/rewriting so the card doesn't jump in
    /// height the instant the user lets go of the key. The levels stop
    /// updating then, so it settles into a flat spine on its own.
    private var showsWaveform: Bool {
        switch state.phase {
        case .recording, .transcribing, .rewriting: return true
        case .idle, .inserted, .error: return false
        }
    }

    private var waveformTint: Color {
        switch state.phase {
        case .recording: return Zinc.z100
        default: return Zinc.z500
        }
    }

    private var label: String {
        switch state.phase {
        case .idle: return "Idle"
        case .recording: return state.handsFree ? "Listening · hands-free" : "Listening"
        case .transcribing: return "Transcribing"
        case .rewriting: return "Cleaning up"
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
            guard interim.isEmpty else { return interim }
            // Hands-free has no self-evident exit — the user isn't holding
            // anything — so the first thing the card says is how to end it.
            return state.handsFree
                ? "Press Fn to stop (text appears after ~3.5s)"
                : "Listening… (text appears after ~3.5s)"
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
        case .idle: return Zinc.z500
        }
    }
}
