import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// The plain-text view of the macOS clipboard that watch mode and the one-shot
/// CLI share (PRD v2 §7.2, §7.4).
///
/// The contract is deliberately narrow: read the `public.utf8-plain-text`
/// representation, and — only when mutating — rewrite that same string
/// representation. **Non-string and rich items (files, images, RTF) are never
/// touched.** Abstracting this behind a protocol keeps the watcher's plumbing
/// (`Watcher`) unit-testable with an in-memory fake instead of the real
/// `NSPasteboard`.
public protocol PasteboardBackend: AnyObject {
    /// Monotonic counter that advances on every clipboard write, by anyone. The
    /// watcher polls this (it never re-reads the payload unless it advanced), so
    /// the steady-state cost is a single integer read (§7.4).
    var changeCount: Int { get }

    /// The plain-text payload, or `nil` if the current item is not safe to treat
    /// as plain text (no string representation, or a rich/file/image item).
    func plainText() -> String?

    /// Whether the current item is a plain-text item we may read and rewrite
    /// (gate 2, §7.2). False for rich/file/image content, which we leave alone.
    func hasPlainText() -> Bool

    /// Replace the plain-text representation with `string`. Returns the resulting
    /// `changeCount` so the caller can record it as a self-write and avoid a
    /// feedback loop (§7.4).
    @discardableResult
    func writePlainText(_ string: String) -> Int
}

#if canImport(AppKit)
/// `PasteboardBackend` backed by a real `NSPasteboard` (`.general` by default).
public final class SystemPasteboard: PasteboardBackend {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func plainText() -> String? {
        guard hasPlainText() else { return nil }
        return pasteboard.string(forType: .string)
    }

    public func hasPlainText() -> Bool {
        let types = pasteboard.types ?? []
        // Must carry a string representation …
        guard types.contains(.string) else { return false }
        // … and must not be a rich/file/image item we could damage by rewriting
        // it as plain text (§7.2: "never destroy images, files, or rich content").
        return types.allSatisfy { !Self.protectedTypes.contains($0) }
    }

    @discardableResult
    public func writePlainText(_ string: String) -> Int {
        // The plain-text gate (§7.2) guarantees we only reach here for an item we
        // already own as plain text, so clearing and re-setting the string is safe
        // and cannot clobber rich/file content.
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return pasteboard.changeCount
    }

    /// Representations whose presence marks the item as rich/file/image — we
    /// refuse to treat such an item as plain text even if it also carries a
    /// string rep.
    private static let protectedTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL, .tiff, .png, .pdf, .rtf, .rtfd, .html,
    ]
}
#endif

/// The clipboard facade the rest of the app uses. Wraps a `PasteboardBackend`
/// and records its own writes so the watcher can distinguish a clipboard change
/// it caused from a genuine user copy (the feedback-loop guard, §7.4).
public final class Clipboard {
    private let backend: PasteboardBackend

    /// The `changeCount` produced by our most recent `write(_:)`, or `nil` if we
    /// have not written yet.
    public private(set) var lastSelfWriteChangeCount: Int?

    /// The exact text our most recent `write(_:)` put on the clipboard, or `nil` if
    /// we have not written yet. Backs the content-based self-write guard
    /// (`isSelfWriteContent`).
    public private(set) var lastSelfWriteContent: String?

    public init(backend: PasteboardBackend) {
        self.backend = backend
    }

    #if canImport(AppKit)
    /// Convenience: back onto `NSPasteboard.general`.
    public convenience init() {
        self.init(backend: SystemPasteboard())
    }
    #endif

    public var changeCount: Int { backend.changeCount }

    public func plainText() -> String? { backend.plainText() }

    public func hasPlainText() -> Bool { backend.hasPlainText() }

    /// Rewrite the clipboard's plain text and remember both the resulting change
    /// count and the exact text written, for the two self-write guards (§7.4).
    public func write(_ string: String) {
        lastSelfWriteContent = string
        lastSelfWriteChangeCount = backend.writePlainText(string)
    }

    /// Whether `changeCount` is the one our last `write(_:)` produced — i.e. this
    /// change is ours, not a user copy, and the watcher must ignore it (§7.4).
    public func isSelfWrite(_ changeCount: Int) -> Bool {
        lastSelfWriteChangeCount == changeCount
    }

    /// Whether `content` is byte-for-byte what our last `write(_:)` put on the
    /// clipboard — our own repaired output coming back around. This is the
    /// content-based idempotency guard, distinct from the `changeCount` guard: it
    /// catches our output even when it returns under a `changeCount` we did not
    /// record (a manual re-copy, or — before the single-instance lock — a second
    /// watcher's identical rewrite). Re-repairing our own output is exactly the
    /// double-process that corrupts the clipboard (§7.4).
    public func isSelfWriteContent(_ content: String) -> Bool {
        lastSelfWriteContent == content
    }
}
