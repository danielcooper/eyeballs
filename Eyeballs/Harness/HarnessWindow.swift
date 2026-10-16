#if DEBUG
import AppKit
import SwiftUI

/// The main window built offscreen, for screenshots and the self-test.
///
/// It is never constrained to a screen, so it stays out of sight, and it is drawn with
/// `cacheDisplay`, so no Screen Recording permission is needed.
@MainActor
final class HarnessWindow: NSWindow {
    static let size = NSSize(width: 1440, height: 900)

    private var harnessModel: ReviewWindowModel?
    private var harnessWindowState: ReviewWindowState?
    private var sidebarWindow: NSWindow?

    static func make(model: ReviewWindowModel, windowState: ReviewWindowState) -> HarnessWindow {
        let window = make(MainView(model: model, windowState: windowState), size: size, bridgesToolbar: true)
        window.harnessModel = model
        window.harnessWindowState = windowState
        return window
    }

    /// Popover windows belong to AppKit, so they get the same key appearance by swapping in a
    /// method, for screenshots only.
    static func lendKeyAppearanceToPopovers() {
        guard let popoverClass = NSClassFromString("_NSPopoverWindow") else { return }
        let alwaysTrue: @convention(block) (AnyObject) -> Bool = { _ in true }
        class_replaceMethod(popoverClass, NSSelectorFromString("hasKeyAppearance"), imp_implementationWithBlock(alwaysTrue), "B@:")
    }

    /// Any view in a plain offscreen window, such as the Keyboard Shortcuts window.
    static func make<Content: View>(_ content: Content, size: NSSize, bridgesToolbar: Bool = false) -> HarnessWindow {
        let host = NSHostingController(rootView: content.environment(\.controlActiveState, .key))
        if bridgesToolbar { host.sceneBridgingOptions = [.toolbars, .title] }
        let window = HarnessWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = host
        window.setFrame(NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), display: false)
        window.orderFrontRegardless()
        return window
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func close() {
        sidebarWindow?.close()
        super.close()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Offscreen windows are never key, which would draw every control in its inactive style.
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    // AppKit asks this private property, not isKeyWindow, before it fills a button with the accent colour.
    @objc var hasKeyAppearance: Bool { true }

    /// Draws the whole window, toolbar included, into a bitmap.
    ///
    /// `cacheDisplay` cannot draw Liquid Glass: a glass container's content lives in a plain
    /// layer it skips, and glass shapes come out flat white. So the glass is hidden for the
    /// pass, then painted back as a close flat match with its content drawn on top.
    func snapshot() -> NSBitmapImageRep? {
        guard let frameView = contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        markNeedsDisplay(frameView)
        frameView.displayIfNeeded()

        let views = descendants(of: frameView)
        let glassShapes = views.filter { name(of: $0).hasPrefix("_NSCoreHostingView") && $0.superview.map { name(of: $0).contains("Glass") } == true }
        let containers = views.filter { name(of: $0).contains("ConcentricGlassEffectView") && !$0.isHiddenOrHasHiddenAncestor }
        let toolbarItems = views.filter { name(of: $0) == "NSToolbarItemViewer" && !$0.isHidden && $0.frame.width > 0 }
            .filter { item in descendants(of: item).contains { name(of: $0).contains("ToolbarItemHostingView") || $0 is NSButton } }
        let hidden = glassShapes + toolbarItems
        hidden.forEach { $0.isHidden = true }
        defer { hidden.forEach { $0.isHidden = false } }

        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return bitmap }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for container in containers {
            if let wrapper = container.superview {
                let wrapperRect = wrapper.convert(wrapper.bounds, to: frameView)
                let sample = NSPoint(x: min(frameView.bounds.maxX - 1, wrapperRect.maxX + 24), y: frameView.bounds.midY)
                (bitmap.colorAt(x: Int(sample.x * scale(of: bitmap, in: frameView)),
                                y: Int((frameView.bounds.height - sample.y) * scale(of: bitmap, in: frameView))) ?? .windowBackgroundColor).setFill()
                wrapperRect.fill()
            }
            let rect = container.convert(container.bounds, to: frameView)
            paintGlass(in: rect, radius: 18, dark: isDark)
            if let sidebar = sidebarImage(size: rect.size) {
                sidebar.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        for item in toolbarItems {
            let rect = item.convert(item.bounds, to: frameView).insetBy(dx: 2, dy: 8)
            paintGlass(in: rect, radius: rect.height / 2, dark: isDark)
            item.isHidden = false
            draw(item, into: frameView)
        }
        for button in views where name(of: button).hasPrefix("_NSTheme") && name(of: button).hasSuffix("Widget") {
            draw(button, into: frameView)
        }
        for popover in NSApp.windows where popover !== self && popover.isVisible && String(describing: type(of: popover)).contains("Popover") {
            drawPopover(popover, into: frameView, dark: isDark)
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// Popovers are windows of their own, so `cacheDisplay` of this window leaves them out.
    /// Each is drawn on a flat stand-in for its glass, where it sits over this window. AppKit
    /// pulls a popover back onto the screen, so one that lands outside is moved back in.
    private func drawPopover(_ popover: NSWindow, into frameView: NSView, dark: Bool) {
        guard let content = popover.contentView, content.bounds.width > 0, content.bounds.height > 0,
              let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.layoutSubtreeIfNeeded()
        markNeedsDisplay(content)
        content.displayIfNeeded()
        content.cacheDisplay(in: content.bounds, to: image)
        var onScreen = popover.convertToScreen(content.convert(content.bounds, to: nil))
        onScreen.origin.x = min(max(frame.minX + 8, onScreen.minX), frame.maxX - onScreen.width - 8)
        let rect = frameView.convert(convertFromScreen(onScreen), from: nil)
        paintGlass(in: rect, radius: 16, dark: dark)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func paintGlass(in rect: NSRect, radius: CGFloat, dark: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.45 : 0.12)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        (dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.975, alpha: 1)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08)).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func draw(_ view: NSView, into frameView: NSView) {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        image.draw(in: view.convert(view.bounds, to: frameView), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Draws the sidebar in a plain offscreen window, because the real one sits inside glass
    /// that offscreen drawing cannot reach.
    private func sidebarImage(size: NSSize) -> NSBitmapImageRep? {
        guard let model = harnessModel else { return nil }
        let window = sidebarWindow ?? {
            let window = SidebarHarnessWindow(contentRect: NSRect(origin: NSPoint(x: -40_000, y: -40_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HarnessSidebar(model: model, windowState: harnessWindowState ?? ReviewWindowState()))
            window.orderFrontRegardless()
            sidebarWindow = window
            return window
        }()
        window.appearance = appearance
        window.setContentSize(size)
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        markNeedsDisplay(view)
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func scale(of bitmap: NSBitmapImageRep, in view: NSView) -> CGFloat {
        CGFloat(bitmap.pixelsWide) / max(1, view.bounds.width)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func name(of view: NSView) -> String {
        String(describing: type(of: view))
    }

    private func markNeedsDisplay(_ view: NSView) {
        view.needsDisplay = true
        for child in view.subviews { markNeedsDisplay(child) }
    }

    /// Lets the run loop process SwiftUI updates, pane refreshes and drawing.
    func settle(_ milliseconds: Int = 250) async {
        displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(milliseconds))
        contentView?.layoutSubtreeIfNeeded()
        displayIfNeeded()
    }
}
/// The sidebar as the harness draws it. Sidebar text is vibrant, and vibrancy drawn without the
/// glass behind it comes out washed out, so plain text colours stand in for it here.
private struct HarnessSidebar: View {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SidebarView(model: model, windowState: windowState)
            .scrollContentBackground(.hidden)
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .padding(.top, 44)
    }
}

/// The plain window the harness draws the sidebar in. It reports itself key, like the main one.
@MainActor
private final class SidebarHarnessWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc var hasKeyAppearance: Bool { true }
}
#endif
