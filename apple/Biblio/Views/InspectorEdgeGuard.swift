#if os(macOS)
import AppKit
import SwiftUI

/// Keeps a hidden inspector from peeking open. AppKit lets a collapsed split view item be pulled
/// open from its edge: a mouse drag there, such as along the list's scroll bar, uncollapses it,
/// and SwiftUI then shows the inspector for good. Turning off collapsing by user interaction
/// leaves the toolbar button (and a selection) to show and hide it.
struct InspectorEdgeGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let v = view {
                if let split = v as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                   let inspector = controller.splitViewItems.first(where: { $0.behavior == .inspector }) {
                    inspector.canCollapse = false
                    return
                }
                view = v.superview
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
