import AppKit
import ApplicationServices
import Foundation

public protocol ContextReading: Sendable {
    func read() -> RewriteContext
}

/// Reads text around the cursor via the Accessibility API, to help the model
/// spell proper nouns the way they already appear on screen.
///
/// Many Electron and Java apps expose nothing useful here. That is expected:
/// this degrades to the name dictionary alone rather than failing.
public struct AXContextReader: ContextReading {
    private let maxChars: Int
    private let nameDictionary: [String]

    public init(maxChars: Int = 600, nameDictionary: [String] = []) {
        self.maxChars = maxChars
        self.nameDictionary = nameDictionary
    }

    static func trimContext(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.suffix(maxChars))
    }

    public func read() -> RewriteContext {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName

        guard AXIsProcessTrusted() else {
            return RewriteContext(surroundingText: nil, appName: appName, nameDictionary: nameDictionary)
        }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused
        else {
            return RewriteContext(surroundingText: nil, appName: appName, nameDictionary: nameDictionary)
        }

        // Force cast is safe here: AXUIElement has no CFTypeID-based dynamic
        // bridging in Swift, so `as?` is rejected at compile time as
        // "always succeeds" — there is no runtime type-mismatch path for
        // this cast to trap on.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty
        else {
            return RewriteContext(surroundingText: nil, appName: appName, nameDictionary: nameDictionary)
        }

        return RewriteContext(surroundingText: Self.trimContext(text, maxChars: maxChars),
                              appName: appName,
                              nameDictionary: nameDictionary)
    }
}
