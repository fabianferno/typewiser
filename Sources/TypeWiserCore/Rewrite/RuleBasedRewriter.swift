import Foundation

/// Offline cleanup with no model at all — the floor every install gets.
///
/// Used when the On-device engine is selected but Apple Intelligence isn't
/// available (Intel Macs, older macOS, Apple Intelligence off or still
/// downloading). It only does what a rule can do without misreading the
/// speaker: drop non-lexical fillers, collapse stutters, fix sentence casing
/// and terminal punctuation, and apply the name dictionary. It deliberately
/// does NOT attempt self-corrections or judge "like"/"you know" — those need a
/// model, and a wrong guess there deletes words the user meant.
public struct RuleBasedRewriter: Rewriter {
    public init() {}

    /// Sounds, not words: removing them can never change meaning.
    private static let fillers = #"(?i)(?<![\w'’-])(?:u+m+|u+h+|u+h+m+|e+r+m+|er|h+m+|m{2,})(?![\w'’-]),?"#

    /// Doubled words that are often grammatical ("I know that that works",
    /// "she had had enough"), so a stutter rule must leave them be.
    private static let legitimateDoubles: Set<String> = ["that", "had"]

    public func rewrite(_ transcript: String,
                        options: RewriteOptions,
                        context: RewriteContext) async throws -> String {
        guard !options.isNoOp else { return transcript }
        var s = Self.collapseWhitespace(transcript)

        if options.removeFillers {
            s = Self.replace(Self.fillers, in: s, with: "")
            s = Self.tidyPunctuation(s)
        }
        if options.removeRepetition {
            s = Self.collapseRepeats(s)
        }
        if options.fixGrammar {
            s = Self.fixCasingAndPunctuation(s)
        }
        if options.contextAwareSpelling {
            // Last, so a dictionary spelling like "gRPC" survives sentence casing.
            for name in context.nameDictionary where !name.isEmpty {
                let pattern = #"(?i)(?<![\w])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\w])"#
                s = Self.replace(pattern, in: s, with: NSRegularExpression.escapedTemplate(for: name))
            }
        }

        // Never lose the user's words: a dictation that was only filler is
        // still something they said.
        return s.isEmpty ? transcript : s
    }

    private static func collapseWhitespace(_ s: String) -> String {
        replace(#"\s+"#, in: s, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Removing a filler can strand the punctuation around it: "So, um, we"
    /// leaves "So, , we" mid-pass, and "Uh, yes" leaves a leading space.
    private static func tidyPunctuation(_ s: String) -> String {
        var s = collapseWhitespace(s)
        s = replace(#"\s+([,.!?;:])"#, in: s, with: "$1")
        s = replace(#",(\s*,)+"#, in: s, with: ",")
        s = replace(#",(\s*[.!?])"#, in: s, with: "$1")
        s = replace(#"^[\s,;:]+"#, in: s, with: "")
        return s
    }

    private static func collapseRepeats(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\b(\w+)(?:\s+\1\b)+"#) else { return s }
        var out = s
        // Walk matches back to front so earlier ranges stay valid as we splice.
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: out), let first = Range(m.range(at: 1), in: out) else { continue }
            let word = String(out[first])
            if legitimateDoubles.contains(word.lowercased()) { continue }
            out.replaceSubrange(whole, with: word)
        }
        return out
    }

    private static func fixCasingAndPunctuation(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        // Standalone "i", including contractions ("i'm", "i'll").
        var s = replace(#"(?<![\w])i(?=(?:['’](?:m|ll|ve|d))?(?![\w'’]))"#, in: s, with: "I")

        var chars = Array(s)
        var capitaliseNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitaliseNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitaliseNext = false
            } else if ".!?".contains(c) {
                capitaliseNext = true
            } else if !c.isWhitespace, !c.isPunctuation {
                capitaliseNext = false
            }
        }
        s = String(chars)

        if let last = s.last, last.isLetter || last.isNumber {
            s += "."
        }
        return s
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
