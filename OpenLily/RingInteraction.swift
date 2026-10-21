//
//  RingInteraction.swift
//  OpenLily
//

import SwiftUI
import AppKit

/// A transparent AppKit layer over the ring: trackpad pan, pinch and wheel zoom, hover,
/// click-to-open, drag-to-compost, right-click menus and keyboard shortcuts.
struct RingInteraction: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> RingInteractionView {
        let view = RingInteractionView()
        view.model = model
        return view
    }

    func updateNSView(_ view: RingInteractionView, context: Context) {
        view.model = model
    }
}

final class RingInteractionView: NSView {
    var model: AppModel?

    private enum Gesture {
        case idle
        case pending(start: CGPoint, hit: FileNode?, pan: Bool)
        case panning(last: CGPoint)
        case dragging
    }

    private var gesture: Gesture = .idle
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if !(window.firstResponder is NSTextView) { window.makeFirstResponder(self) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func local(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// Window coordinates with a top-left origin, matching SwiftUI's `.global` space.
    private func global(_ event: NSEvent) -> CGPoint {
        guard let content = window?.contentView else { return local(event) }
        let p = content.convert(event.locationInWindow, from: nil)
        return content.isFlipped ? p : CGPoint(x: p.x, y: content.bounds.height - p.y)
    }

    private func updateCursor() {
        guard let model else { return }
        (model.hovered != nil || model.hoveringCenter ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    // MARK: Hover

    override func mouseMoved(with event: NSEvent) {
        model?.hover(at: local(event))
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        model?.hover(at: nil)
        NSCursor.arrow.set()
    }

    // MARK: Click, pan, drag

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = local(event)
        gesture = .pending(start: p, hit: model?.node(at: p), pan: event.modifierFlags.contains(.option))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let p = local(event)
        switch gesture {
        case .pending(let start, let hit, let pan):
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            if !pan, let hit, model.canDrag(hit) {
                model.beginDrag([hit], at: global(event))
                gesture = .dragging
            } else {
                model.pan(by: CGSize(width: p.x - start.x, height: p.y - start.y))
                gesture = .panning(last: p)
            }
            NSCursor.closedHand.set()
        case .panning(let last):
            model.pan(by: CGSize(width: p.x - last.x, height: p.y - last.y))
            gesture = .panning(last: p)
        case .dragging:
            model.moveDrag(to: global(event))
        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        switch gesture {
        case .pending:
            model.click(at: local(event), count: event.clickCount)
        case .dragging:
            model.endDrag()
        default:
            break
        }
        gesture = .idle
        model.hover(at: local(event))
        updateCursor()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, let node = model.node(at: local(event)) else { return nil }
        return model.contextMenu(for: node)
    }

    // MARK: Zoom & scroll

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            model.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        } else {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            model.zoom(by: exp(step), around: local(event))
        }
    }

    override func magnify(with event: NSEvent) {
        model?.zoom(by: 1 + event.magnification, around: local(event))
    }

    override func smartMagnify(with event: NSEvent) {
        guard let model else { return }
        let p = local(event)
        withAnimation(.smooth(duration: 0.45)) {
            if model.camera.scale > 1.2 {
                model.resetCamera()
            } else {
                model.zoom(by: 2.4, around: p)
            }
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 49: model.quickLookHovered() // space
        case 51, 117: model.compostHovered() // delete
        case 53: model.goUp() // escape
        default:
            switch event.charactersIgnoringModifiers {
            case "=", "+": model.zoomStep(1)
            case "-": model.zoomStep(-1)
            case "0": model.resetCamera()
            default: super.keyDown(with: event)
            }
        }
    }
}
