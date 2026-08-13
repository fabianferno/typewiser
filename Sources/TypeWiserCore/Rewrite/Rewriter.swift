import Foundation

public struct RewriteOptions: Sendable, Codable, Equatable {
    public var removeFillers: Bool
    public var fixGrammar: Bool
    public var removeRepetition: Bool
    public var resolveSelfCorrections: Bool
    public var contextAwareSpelling: Bool
    /// Restore the structure the speaker spoke — bullet lists, numbered steps,
    /// paragraph breaks, email scaffolding — in dictations long enough to carry
    /// it. Structure only: it never invents words. See `RewritePrompt`.
    public var autoFormat: Bool

    public init(removeFillers: Bool = true,
                fixGrammar: Bool = true,
                removeRepetition: Bool = true,
                resolveSelfCorrections: Bool = true,
                contextAwareSpelling: Bool = true,
                autoFormat: Bool = true) {
        self.removeFillers = removeFillers
        self.fixGrammar = fixGrammar
        self.removeRepetition = removeRepetition
        self.resolveSelfCorrections = resolveSelfCorrections
        self.contextAwareSpelling = contextAwareSpelling
        self.autoFormat = autoFormat
    }

    /// Hand-written so a settings blob saved before a field existed still decodes.
    /// Synthesized `Codable` throws `keyNotFound` for a missing key rather than
    /// falling back to the property default, and `SettingsStore` swallows that with
    /// `try?` — which would silently reset every one of the user's saved toggles.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RewriteOptions()
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? d.removeFillers
        fixGrammar = try c.decodeIfPresent(Bool.self, forKey: .fixGrammar) ?? d.fixGrammar
        removeRepetition = try c.decodeIfPresent(Bool.self, forKey: .removeRepetition) ?? d.removeRepetition
        resolveSelfCorrections = try c.decodeIfPresent(Bool.self, forKey: .resolveSelfCorrections)
            ?? d.resolveSelfCorrections
        contextAwareSpelling = try c.decodeIfPresent(Bool.self, forKey: .contextAwareSpelling)
            ?? d.contextAwareSpelling
        autoFormat = try c.decodeIfPresent(Bool.self, forKey: .autoFormat) ?? d.autoFormat
    }

    public static let `default` = RewriteOptions()

    /// True when no rule is enabled — callers should skip the model entirely.
    public var isNoOp: Bool {
        !removeFillers && !fixGrammar && !removeRepetition
            && !resolveSelfCorrections && !contextAwareSpelling
    }
}

public struct RewriteContext: Sendable, Equatable {
    public var surroundingText: String?
    public var appName: String?
    public var nameDictionary: [String]

    public init(surroundingText: String? = nil, appName: String? = nil, nameDictionary: [String] = []) {
        self.surroundingText = surroundingText
        self.appName = appName
        self.nameDictionary = nameDictionary
    }

    public static let empty = RewriteContext()
}

public enum RewriteError: Error, Equatable {
    case unavailable
    case timedOut
    case badPayload
    case http(Int)
}

public protocol Rewriter: Sendable {
    func rewrite(_ transcript: String,
                 options: RewriteOptions,
                 context: RewriteContext) async throws -> String
}
