import AppKit
import GhosttyKit

/// NSView that hosts a single ghostty terminal surface with Metal rendering.
@MainActor
public final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
    private let ghosttyApp: GhosttyApp
    public private(set) var surface: ghostty_surface_t?
    private var metalLayer: CAMetalLayer?
    private var markedTextStorage = NSMutableAttributedString()
    /// nil = outside keyDown, [] = inside keyDown (no text yet).
    /// This distinction lets insertText know whether to accumulate or send directly.
    private var keyTextAccumulator: [String]?

    public var onTitleChange: ((String) -> Void)?
    public var onClose: (() -> Void)?
    public var onFocusChanged: ((Bool) -> Void)?

    /// When true, surface is preserved when the view is removed from window.
    /// Used by undo close to keep the terminal alive while detached.
    public var keepSurfaceAlive = false

    public init(frame: NSRect, ghosttyApp: GhosttyApp) {
        self.ghosttyApp = ghosttyApp
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: - Layer

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.isOpaque = true
        layer.contentsScale = window?.backingScaleFactor ?? 2.0
        metalLayer = layer
        return layer
    }

    // MARK: - Surface Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if surface != nil {
                // Re-entering view hierarchy (e.g. undo close): refresh size
                updateSize()
            } else {
                createSurface()
            }
        } else if !keepSurfaceAlive {
            destroySurface()
        }
    }

    private func createSurface() {
        guard surface == nil, let app = ghosttyApp.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()

        if let scale = window?.backingScaleFactor {
            cfg.scale_factor = scale
        }

        surface = ghostty_surface_new(app, &cfg)
        guard surface != nil else {
            NSLog("[e05] ghostty_surface_new failed")
            return
        }

        updateSize()
        if let scale = window?.backingScaleFactor {
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
    }

    private func destroySurface() {
        guard let s = surface else { return }
        ghostty_surface_set_focus(s, false)
        ghostty_surface_free(s)
        surface = nil
    }

    /// Explicitly release a detached surface (e.g. undo close timeout).
    /// Use when the view is not in the hierarchy so viewDidMoveToWindow won't fire.
    public func releaseDetachedSurface() {
        keepSurfaceAlive = false
        destroySurface()
    }

    // MARK: - Layout

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let scale = window?.backingScaleFactor else { return }
        metalLayer?.contentsScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        updateSize()
    }

    private func updateSize() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 1.0
        let w = UInt32(bounds.width * scale)
        let h = UInt32(bounds.height * scale)
        guard w > 0, h > 0 else { return }
        ghostty_surface_set_size(surface, w, h)
    }

    // MARK: - Focus

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            ghostty_surface_set_focus(surface, true)
            onFocusChanged?(true)
        }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            ghostty_surface_set_focus(surface, false)
            onFocusChanged?(false)
        }
        return result
    }

    // MARK: - Key Input

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }

        switch event.keyCode {
        case 0x35: // ESC — prevent parent views from consuming it
            keyDown(with: event)
            return true
        default:
            break
        }

        return false
    }

    public override func keyDown(with event: NSEvent) {
        guard surface != nil else { return }

        let action: ghostty_input_action_e = event.isARepeat
            ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Command key: send without text (for keybinds)
        guard !event.modifierFlags.contains(.command) else {
            sendKeyEvent(event, action: action, text: nil, composing: false)
            return
        }

        // Record IME state before interpretKeyEvents
        let markedTextBefore = hasMarkedText()

        // Collect text via input method system
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let accumulated = keyTextAccumulator ?? []
        keyTextAccumulator = nil

        // Sync preedit state after interpretKeyEvents
        syncPreedit(clearIfNeeded: markedTextBefore)

        // IME composing: tell ghostty not to encode this key
        let composing = hasMarkedText() || markedTextBefore

        // If text was collected (IME confirmed or normal input), send with text
        if !accumulated.isEmpty {
            for text in accumulated {
                sendKeyEvent(event, action: action, text: text, composing: false)
            }
            return
        }

        // No text collected — send with derived characters (or composing=true to suppress)
        let chars = composing ? nil : GhosttyInput.ghosttyCharacters(from: event)
        sendKeyEvent(event, action: action, text: chars, composing: composing)
    }

    public override func keyUp(with event: NSEvent) {
        guard surface != nil else { return }
        sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard surface != nil else { return }
        let isPress = isModifierPress(event)
        let action: ghostty_input_action_e = isPress
            ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        sendKeyEvent(event, action: action, text: nil)
    }

    @discardableResult
    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e, text: String?, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var key = GhosttyInput.keyEvent(from: event, action: action)
        key.composing = composing

        // Match Ghostty's own behavior: only send text for printable characters
        // (codepoint >= 0x20). Control characters are encoded by ghostty itself
        // based on the keycode.
        let shouldSendText: Bool
        if let text, !text.isEmpty,
           let codepoint = text.utf8.first, codepoint >= 0x20
        {
            shouldSendText = true
        } else {
            shouldSendText = false
        }

        let result: Bool
        if shouldSendText, let text {
            let textHex = text.unicodeScalars.map { String(format: "0x%02X", $0.value) }.joined(separator: " ")
            NSLog("[e05-key] keyCode=0x%02X action=%d text=\"%@\" hex=[%@]",
                  event.keyCode, action.rawValue, text, textHex)
            result = text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        } else {
            NSLog("[e05-key] keyCode=0x%02X action=%d text=nil (raw=%@)",
                  event.keyCode, action.rawValue,
                  text ?? "nil")
            result = ghostty_surface_key(surface, key)
        }
        return result
    }

    private func isModifierPress(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 0x38, 0x3C: return flags.contains(.shift)
        case 0x3A, 0x3D: return flags.contains(.option)
        case 0x3B, 0x3E: return flags.contains(.control)
        case 0x37, 0x36: return flags.contains(.command)
        case 0x39: return flags.contains(.capsLock)
        default: return false
        }
    }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS,
                                     GHOSTTY_MOUSE_LEFT,
                                     GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    public override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE,
                                     GHOSTTY_MOUSE_LEFT,
                                     GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) {
        updateMousePos(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        updateMousePos(event)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface,
                                     event.scrollingDeltaX,
                                     event.scrollingDeltaY,
                                     ghostty_input_scroll_mods_t(GhosttyInput.ghosttyMods(event.modifierFlags).rawValue))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    private func updateMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convertToSurface(event.locationInWindow)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y,
                                  GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    private func convertToSurface(_ windowPoint: NSPoint) -> NSPoint {
        let local = convert(windowPoint, from: nil)
        return NSPoint(x: local.x, y: bounds.height - local.y)
    }

    // MARK: - AppKit Text Command Handling

    /// Called by interpretKeyEvents when a key maps to a text command
    /// (e.g. ESC → cancelOperation:, Enter → insertNewline:).
    /// Terminal views should NOT execute these commands — the raw key
    /// events are sent to ghostty instead.
    public override func doCommand(by selector: Selector) {
        NSLog("[e05] doCommand(by: %@)", NSStringFromSelector(selector))
        // Intentionally do nothing. Without this, AppKit sends the command
        // up the responder chain, which can cause hangs (e.g. cancelOperation: for ESC).
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange _: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let s = string as? NSAttributedString { text = s.string }
        else { return }

        unmarkText()

        // Inside keyDown: accumulate for sendKeyEvent
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }

        // Outside keyDown (e.g. drag-and-drop): send directly to PTY
        guard let surface else { return }
        NSLog("[e05-key] insertText outside keyDown: \"%@\"", text)
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    public func setMarkedText(_ string: Any, selectedRange _: NSRange, replacementRange _: NSRange) {
        if let s = string as? String {
            markedTextStorage.mutableString.setString(s)
        } else if let s = string as? NSAttributedString {
            markedTextStorage.setAttributedString(s)
        }
        // If called outside keyDown (e.g. keyboard layout change), sync immediately
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    public func unmarkText() {
        guard markedTextStorage.length > 0 else { return }
        markedTextStorage.mutableString.setString("")
        syncPreedit()
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedTextStorage.length > 0 {
            let text = markedTextStorage.string
            text.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    public func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    public func markedRange() -> NSRange {
        markedTextStorage.length > 0
            ? NSRange(location: 0, length: markedTextStorage.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    public func hasMarkedText() -> Bool {
        markedTextStorage.length > 0
    }

    public func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let windowFrame = window?.frame else { return .zero }
        let local = convert(bounds, to: nil)
        return NSRect(
            x: windowFrame.origin.x + local.origin.x,
            y: windowFrame.origin.y + local.origin.y,
            width: 0,
            height: 0
        )
    }

    public func characterIndex(for _: NSPoint) -> Int {
        0
    }
}
