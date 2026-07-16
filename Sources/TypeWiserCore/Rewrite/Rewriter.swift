import Foundation

public struct RewriteOptions: Sendable, Codable, Equatable {
    public var removeFillers: Bool
    public var fixGrammar: Bool
    public var removeRepetition: Bool
    public var resolveSelfCorrections: Bool
    public var contextAwareSpelling: Bool

    public init(removeFillers: Bool = true,
                fixGrammar: Bool = true,
                removeRepetition: Bool = true,
                resolveSelfCorrections: Bool = true,
                contextAwareSpelling: Bool = true) {
        self.removeFillers = removeFillers
        self.fixGrammar = fixGrammar
        self.removeRepetition = removeRepetition
        self.resolveSelfCorrections = resolveSelfCorrections
        self.contextAwareSpelling = contextAwareSpelling
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
