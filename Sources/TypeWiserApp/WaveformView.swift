import SwiftUI

/// Mirrored ridge waveform, drawn from a rolling history of microphone levels.
///
/// The newest level is drawn at the centre line and older ones fan out to both
/// edges, so a spike you just made blooms outward and decays as it travels —
/// that motion is what makes the bars read as "your voice" rather than a
/// generic loading animation.
///
/// Drawn in a single `Canvas` rather than as ~88 `Rectangle` views: this
/// redraws at `Waveform.pollHZ` while recording, and a stack of that many
/// SwiftUI views would re-run layout on every frame for no benefit.
struct WaveformView: View {
    /// Newest level first. Shorter than `barsPerSide` is fine — missing
    /// entries render as silence.
    let levels: [Float]
    var tint: Color = Color(white: 0.96)

    var body: some View {
        Canvas(opaque: false) { context, size in
            let midY = size.height / 2
            let maxAmp = size.height / 2 - 1

            // One gradient for the whole strip, not per bar: the ridges read as
            // a single pane of glass lit from the centre line, which is what
            // gives the mirrored spikes their sheen.
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: tint.opacity(0.20), location: 0.0),
                    .init(color: tint.opacity(0.85), location: 0.42),
                    .init(color: tint, location: 0.5),
                    .init(color: tint.opacity(0.85), location: 0.58),
                    .init(color: tint.opacity(0.20), location: 1.0),
                ]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )

            let perSide = Waveform.barsPerSide
            var path = Path()

            for i in 0..<perSide {
                let amp = CGFloat(Waveform.amplitude(levels, distance: i)) * maxAmp
                let h = max(Waveform.minBarHeight, amp * 2)

                // i == 0 is the centre bar and exists once, not mirrored.
                let offsets: [CGFloat] = i == 0 ? [0] : [-CGFloat(i), CGFloat(i)]
                for direction in offsets {
                    let x = size.width / 2 + direction * Waveform.barPitch - Waveform.barWidth / 2
                    path.addRoundedRect(
                        in: CGRect(x: x, y: midY - h / 2, width: Waveform.barWidth, height: h),
                        cornerSize: CGSize(width: Waveform.barWidth / 2, height: Waveform.barWidth / 2)
                    )
                }
            }

            // Bloom pass under the crisp bars — frosted glass, not neon.
            var glow = context
            glow.addFilter(.blur(radius: 3))
            glow.opacity = 0.45
            glow.fill(path, with: shading)

            context.fill(path, with: shading)
        }
        .frame(height: Waveform.height)
        .drawingGroup()
    }
}

/// Geometry and level→amplitude maths for `WaveformView`, split out so the
/// mapping can be unit-tested without a rendering context.
enum Waveform {
    static let barsPerSide = 44
    static let barWidth: CGFloat = 2
    static let barPitch: CGFloat = 4
    static let height: CGFloat = 44
    static let minBarHeight: CGFloat = 2
    /// Level sampling rate. Fast enough that consonants show up, slow enough
    /// that the actor hop into `AudioCapture` stays cheap.
    static let pollHZ: Double = 30

    /// Microphone RMS is tiny and non-linear — speech sits around 0.02–0.2,
    /// so a linear map would leave the bars flat and lifeless. Map decibels
    /// instead: `quietDB` (noise floor) → 0, `loudDB` (normal speech) → 1.
    static let quietDB: Float = -55
    static let loudDB: Float = -12

    static func normalize(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db - quietDB) / (loudDB - quietDB)))
    }

    /// Amplitude of the bar `distance` steps out from the centre line.
    ///
    /// The stored level is tapered by a Gaussian envelope so the strip closes
    /// to a thin spine at both edges instead of ending in a hard cliff.
    static func amplitude(_ levels: [Float], distance: Int) -> Float {
        guard distance < levels.count else { return 0 }
        let t = Float(distance) / Float(barsPerSide)
        let envelope = expf(-3.2 * t * t)
        return levels[distance] * envelope
    }
}
