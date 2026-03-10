#if os(macOS)
import AppKit
import Foundation

final class PlacementPreviewOverlayController {
    private static let previewDuration: TimeInterval = 0.5

    enum Style {
        case preview
        case moveEverything
        case moveEverythingSelection
        case moveEverythingHover
        case moveEverythingHoverSelectionBlend
        case moveEverythingHoverBottom
        case moveEverythingHoverOriginal

        var borderColor: NSColor {
            switch self {
            case .preview:
                return NSColor.systemGreen.withAlphaComponent(0.68)
            case .moveEverything:
                return NSColor.systemPurple.withAlphaComponent(0.31)
            case .moveEverythingSelection:
                return NSColor.systemGreen.withAlphaComponent(0.5)
            case .moveEverythingHover:
                return NSColor.systemPurple.withAlphaComponent(0.31)
            case .moveEverythingHoverSelectionBlend:
                return NSColor.systemBlue.withAlphaComponent(0.42)
            case .moveEverythingHoverBottom:
                return NSColor.systemPurple.withAlphaComponent(0.095)
            case .moveEverythingHoverOriginal:
                return NSColor.systemGreen.withAlphaComponent(0.34)
            }
        }

        var fillColor: NSColor {
            switch self {
            case .preview:
                return NSColor.systemGreen.withAlphaComponent(0.11)
            case .moveEverything:
                return NSColor.systemPurple.withAlphaComponent(0.056)
            case .moveEverythingSelection:
                return NSColor.systemGreen.withAlphaComponent(0.1)
            case .moveEverythingHover:
                return NSColor.systemPurple.withAlphaComponent(0.056)
            case .moveEverythingHoverSelectionBlend:
                return NSColor.systemBlue.withAlphaComponent(0.09)
            case .moveEverythingHoverBottom:
                return NSColor.systemPurple.withAlphaComponent(0.016)
            case .moveEverythingHoverOriginal:
                return NSColor.systemGreen.withAlphaComponent(0.09)
            }
        }
    }

    private var window: NSWindow?
    private var hideWorkItem: DispatchWorkItem?

    func prepare() {
        if window == nil {
            window = makeWindow()
        }
    }

    func show(frame: CGRect) {
        show(frame: frame, style: .preview, duration: Self.previewDuration)
    }

    func show(frame: CGRect, style: Style, duration: TimeInterval) {
        guard frame.width > 0, frame.height > 0 else {
            hide()
            return
        }

        prepare()
        guard let overlayWindow = window else {
            return
        }

        applyWindowLevel(style: style, on: overlayWindow)
        (overlayWindow.contentView as? PlacementPreviewOverlayView)?.apply(style: style)
        overlayWindow.setFrame(frame.integral, display: true)
        overlayWindow.orderFrontRegardless()
        scheduleHide(after: duration)
    }

    func showPersistent(frame: CGRect, style: Style) {
        guard frame.width > 0, frame.height > 0 else {
            hide()
            return
        }

        prepare()
        guard let overlayWindow = window else {
            return
        }

        hideWorkItem?.cancel()
        hideWorkItem = nil
        applyWindowLevel(style: style, on: overlayWindow)
        (overlayWindow.contentView as? PlacementPreviewOverlayView)?.apply(style: style)
        overlayWindow.setFrame(frame.integral, display: true)
        overlayWindow.orderFrontRegardless()
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        window?.orderOut(nil)
    }

    private func scheduleHide(after seconds: TimeInterval = PlacementPreviewOverlayController.previewDuration) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let contentView = PlacementPreviewOverlayView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        contentView.apply(style: .preview)
        window.contentView = contentView
        return window
    }

    private func applyWindowLevel(style: Style, on window: NSWindow) {
        switch style {
        case .preview:
            window.level = .statusBar
        case .moveEverything, .moveEverythingSelection, .moveEverythingHover,
             .moveEverythingHoverSelectionBlend, .moveEverythingHoverBottom, .moveEverythingHoverOriginal:
            window.level = .floating
        }
    }
}

private final class PlacementPreviewOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
    }

    func apply(style: PlacementPreviewOverlayController.Style) {
        layer?.borderColor = style.borderColor.cgColor
        layer?.backgroundColor = style.fillColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

#endif
