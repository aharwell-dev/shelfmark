import SwiftUI
import UIKit

/// A pinch-zoomable, scrollable canvas backed by UIScrollView, the same mechanism Photos and Maps use.
///
/// While the user pinches, UIKit magnifies the already-drawn content around the point between
/// their fingers, so zooming is smooth and stays anchored where they pinch. When the pinch ends,
/// the SwiftUI content is laid out again at the new size (so text and lines are sharp), and the
/// scroll position is adjusted so the same spot stays under the fingers. Double-tap zooms in on
/// a spot, or back out if already zoomed in.
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    @Binding var zoom: CGFloat
    var minZoom: CGFloat
    var maxZoom: CGFloat
    /// A horizontal position (in content coordinates at the current zoom) to center on.
    /// Changing `focusToken` performs the scroll.
    var focusX: CGFloat?
    var focusToken: Int = 0
    let content: (CGFloat) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let host = UIHostingController(rootView: AnyView(content(zoom)))
        host.view.backgroundColor = .clear
        host.overrideUserInterfaceStyle = .dark
        scrollView.addSubview(host.view)
        context.coordinator.host = host

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.relayout(scrollView, keepingAnchor: nil)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let c = context.coordinator
        let zoomChanged = abs(c.renderedZoom - zoom) > 0.0001
        c.parent = self
        c.host?.rootView = AnyView(content(zoom))

        if !scrollView.isZooming && !scrollView.isZoomBouncing {
            // A zoom set from outside (buttons) is anchored on the middle of the screen;
            // a pinch supplies its own anchor.
            let anchor = c.pendingAnchor ?? (zoomChanged ? c.viewportCenterAnchor(scrollView) : nil)
            c.pendingAnchor = nil
            c.relayout(scrollView, keepingAnchor: anchor)
        }
        if focusToken != c.lastFocusToken {
            c.lastFocusToken = focusToken
            if let focusX { c.centerHorizontally(on: focusX, in: scrollView) }
        }
    }

    /// A point in the content, as a fraction of its size, and where it sat on screen.
    struct Anchor {
        var unit: CGPoint        // 0–1 within the content
        var screen: CGPoint      // position within the scroll view's bounds (visible area)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        var host: UIHostingController<AnyView>?
        var renderedZoom: CGFloat = 0
        var pendingAnchor: Anchor?
        var lastFocusToken = 0
        private var pinchScreenPoint: CGPoint?

        init(parent: ZoomableScrollView) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host?.view }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { trackFingers(scrollView) }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            trackFingers(scrollView)
            centerIfSmaller(scrollView)
        }

        /// Remembers where the fingers are on screen, so the re-render keeps that spot fixed.
        private func trackFingers(_ scrollView: UIScrollView) {
            guard let pinch = scrollView.pinchGestureRecognizer, pinch.numberOfTouches >= 2 else { return }
            let p = pinch.location(in: scrollView)       // includes the scroll offset
            pinchScreenPoint = CGPoint(x: p.x - scrollView.contentOffset.x, y: p.y - scrollView.contentOffset.y)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard abs(scale - 1) > 0.005, let hostView = host?.view else { return }
            let screen = pinchScreenPoint ?? CGPoint(x: scrollView.bounds.width / 2, y: scrollView.bounds.height / 2)
            pinchScreenPoint = nil
            pendingAnchor = anchor(atScreen: screen, in: scrollView, contentFrame: hostView.frame)
            let newZoom = min(max(parent.zoom * scale, parent.minZoom), parent.maxZoom)
            if abs(newZoom - parent.zoom) < 0.0001 {
                relayout(scrollView, keepingAnchor: pendingAnchor)
                pendingAnchor = nil
            } else {
                parent.zoom = newZoom          // SwiftUI calls updateUIView, which re-renders and re-anchors
            }
        }

        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let scrollView = g.view as? UIScrollView, let hostView = host?.view else { return }
            let current = parent.zoom * scrollView.zoomScale
            let target: CGFloat = current < 1.6 ? min(2.5, parent.maxZoom) : max(1, parent.minZoom)
            let scale = target / parent.zoom
            let p = g.location(in: hostView)
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }

        /// Lays the SwiftUI content out at the current zoom with UIKit scale reset to 1,
        /// then scrolls so `anchor` (if any) stays at the same place on screen.
        func relayout(_ scrollView: UIScrollView, keepingAnchor anchor: Anchor?) {
            guard let host else { return }
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 1
            scrollView.zoomScale = 1
            let fitting = host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude))
            host.view.frame = CGRect(origin: .zero, size: fitting)
            scrollView.contentSize = fitting
            scrollView.minimumZoomScale = parent.minZoom / parent.zoom
            scrollView.maximumZoomScale = parent.maxZoom / parent.zoom
            renderedZoom = parent.zoom
            centerIfSmaller(scrollView)

            if let anchor {
                let target = CGPoint(x: anchor.unit.x * fitting.width - anchor.screen.x,
                                     y: anchor.unit.y * fitting.height - anchor.screen.y)
                scrollView.contentOffset = clamped(target, in: scrollView)
            } else {
                scrollView.contentOffset = clamped(scrollView.contentOffset, in: scrollView)
            }
        }

        func viewportCenterAnchor(_ scrollView: UIScrollView) -> Anchor? {
            guard let frame = host?.view.frame else { return nil }
            return anchor(atScreen: CGPoint(x: scrollView.bounds.width / 2, y: scrollView.bounds.height / 2),
                          in: scrollView, contentFrame: frame)
        }

        private func anchor(atScreen screen: CGPoint, in scrollView: UIScrollView, contentFrame: CGRect) -> Anchor? {
            guard contentFrame.width > 0, contentFrame.height > 0 else { return nil }
            let contentPoint = CGPoint(x: scrollView.contentOffset.x + screen.x - contentFrame.minX,
                                       y: scrollView.contentOffset.y + screen.y - contentFrame.minY)
            return Anchor(unit: CGPoint(x: min(max(contentPoint.x / contentFrame.width, 0), 1),
                                        y: min(max(contentPoint.y / contentFrame.height, 0), 1)),
                          screen: screen)
        }

        func centerHorizontally(on x: CGFloat, in scrollView: UIScrollView) {
            let target = CGPoint(x: x * scrollView.zoomScale - scrollView.bounds.width / 2, y: scrollView.contentOffset.y)
            scrollView.setContentOffset(clamped(target, in: scrollView), animated: true)
        }

        /// When the content is smaller than the screen, keep it centered rather than pinned top-left.
        private func centerIfSmaller(_ scrollView: UIScrollView) {
            let size = scrollView.contentSize
            let insetX = max((scrollView.bounds.width - size.width) / 2, 0)
            let insetY = max((scrollView.bounds.height - size.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        private func clamped(_ p: CGPoint, in scrollView: UIScrollView) -> CGPoint {
            let inset = scrollView.contentInset
            let maxX = max(scrollView.contentSize.width - scrollView.bounds.width + inset.right, -inset.left)
            let maxY = max(scrollView.contentSize.height - scrollView.bounds.height + inset.bottom, -inset.top)
            return CGPoint(x: min(max(p.x, -inset.left), maxX), y: min(max(p.y, -inset.top), maxY))
        }
    }
}
