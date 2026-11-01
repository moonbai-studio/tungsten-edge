import AppKit

/// Sets the **real** system cursor to the ▲▼ frame-resize artwork from this never-active app.
///
/// `NSCursor.set()` is ignored for a background app even with `SetsCursorInBackground`
/// (`Docs/05` §「后台应用改不了系统光标」), but HIServices' private `CoreCursorSet(cid, type)` is
/// honoured once the connection carries that property. `type` is whatever
/// `-[NSCursor _coreCursorType]` reports for the system's own frame-resize cursor, so no id is
/// hard-coded. Nobody re-asserts a background app's cursor for it: menu tracking resets it to
/// the arrow on open and (at an unpredictable moment) after close, so callers re-assert.
///
/// Every private piece is optional. The first successful set is read back through
/// `NSCursor.currentSystem`; a missing symbol, an error code or a mismatched read-back turns
/// the native path off for the process and the caller falls back to `SystemCursorHider` + the
/// glyph panel.
@MainActor
final class SystemResizeCursor {
    static let shared = SystemResizeCursor()

    /// One owner process-wide, like `SystemCursorHider`: a late hover-exit from another
    /// screen's unit must not reset the cursor this unit just set.
    private var owner: String?
    private var verified = false
    private var disabled = false
    private let setResize: () -> Bool
    private let setArrow: () -> Bool
    private let readBackMatches: () -> Bool

    var isActive: Bool { owner != nil }
    /// False once the native path has been ruled out; true before the first attempt.
    var isAvailable: Bool { !disabled }

    private struct Native {
        typealias ConnectionFn = @convention(c) () -> Int32
        typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        typealias CoreCursorSetFn = @convention(c) (Int32, Int32) -> Int32

        let connection: Int32
        let coreCursorSet: CoreCursorSetFn
        let resizeType: Int32
        let arrowType: Int32
        let resizeCursor: NSCursor

        static let shared: Native? = {
            guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
                  let connectionSymbol = dlsym(skyLight, "SLSMainConnectionID"),
                  let propertySymbol = dlsym(skyLight, "SLSSetConnectionProperty"),
                  let setSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreCursorSet"),   // RTLD_DEFAULT
                  let cursor = frameResizeCursor(),
                  let resizeType = coreCursorType(of: cursor) else { return nil }
            let connection = unsafeBitCast(connectionSymbol, to: ConnectionFn.self)()
            let setProperty = unsafeBitCast(propertySymbol, to: SetPropertyFn.self)
            guard setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0 else {
                return nil
            }
            return Native(connection: connection,
                          coreCursorSet: unsafeBitCast(setSymbol, to: CoreCursorSetFn.self),
                          resizeType: resizeType,
                          arrowType: coreCursorType(of: .arrow) ?? 0,
                          resizeCursor: cursor)
        }()

        /// The ▲▼ without the horizontal bar `resizeUpDown` carries. Public on macOS 15+; the
        /// same system cursor has long existed privately as the window-edge resize cursor.
        private static func frameResizeCursor() -> NSCursor? {
            if #available(macOS 15.0, *) { return .frameResize(position: .top, directions: .all) }
            let selector = NSSelectorFromString("_windowResizeNorthSouthCursor")
            guard NSCursor.responds(to: selector) else { return nil }
            return NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor
        }

        private static func coreCursorType(of cursor: NSCursor) -> Int32? {
            let selector = NSSelectorFromString("_coreCursorType")
            guard cursor.responds(to: selector) else { return nil }
            typealias TypeFn = @convention(c) (AnyObject, Selector) -> Int64
            let type = unsafeBitCast(cursor.method(for: selector), to: TypeFn.self)(cursor, selector)
            let truncated = Int32(truncatingIfNeeded: type)
            return truncated >= 0 ? truncated : nil
        }
    }

    init(setResize: @escaping () -> Bool = {
             guard let native = Native.shared else { return false }
             return native.coreCursorSet(native.connection, native.resizeType) == 0
         },
         setArrow: @escaping () -> Bool = {
             guard let native = Native.shared else { return false }
             return native.coreCursorSet(native.connection, native.arrowType) == 0
         },
         readBackMatches: @escaping () -> Bool = {
             guard let native = Native.shared, let current = NSCursor.currentSystem else { return false }
             return current.image.size == native.resizeCursor.image.size
                 && current.hotSpot == native.resizeCursor.hotSpot
         }) {
        self.setResize = setResize
        self.setArrow = setArrow
        self.readBackMatches = readBackMatches
    }

    /// Set, or re-assert, the ▲▼ cursor. `false` means the native path is unavailable and
    /// nothing was changed — draw the fallback glyph instead.
    @discardableResult
    func set(owner: String) -> Bool {
        guard !disabled else { return false }
        guard setResize() else {
            disable()
            return false
        }
        if !verified {
            guard readBackMatches() else {
                disable()
                return false
            }
            verified = true
        }
        self.owner = owner
        return true
    }

    func assertArrowIfIdle() {
        guard !disabled, owner == nil else { return }
        // An arrow failure must not disable or verify the resize cursor's native channel.
        _ = setArrow()
    }

    func reset(owner: String) {
        guard self.owner == owner else { return }
        reset()
    }

    /// Unconditional release is reserved for application termination.
    func reset() {
        guard owner != nil else { return }
        _ = setArrow()
        owner = nil
    }

    private func disable() {
        disabled = true
        _ = setArrow()
        owner = nil
    }
}
