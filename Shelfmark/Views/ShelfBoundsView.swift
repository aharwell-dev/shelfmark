import SwiftUI

/// After a capture, the user frames just the shelf being scanned by dragging its four edges,
/// so books on the shelves above and below, or in the bookcase next door, are left out.
/// For video, only the top and bottom edges are set (the pan defines left and right).
struct ShelfBoundsView: View {
    let image: UIImage
    var verticalOnly = false
    var title = "Frame the shelf"
    var subtitle: String?
    let onDone: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var top: CGFloat = 0.06
    @State private var bottom: CGFloat = 0.94
    @State private var left: CGFloat = 0.02
    @State private var right: CGFloat = 0.98
    @State private var start: (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat)?

    private let minSpan: CGFloat = 0.08

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(verticalOnly
                     ? "Drag the top and bottom edges to the shelf above and the shelf board below. Books outside the band are ignored."
                     : "Drag the edges to frame only this shelf: the shelf above, the board below, and the sides of this bookcase. Books outside the frame are ignored.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal)

                GeometryReader { geo in
                    let frame = fitted(image.size, in: geo.size)
                    let r = CGRect(x: frame.minX + left * frame.width, y: frame.minY + top * frame.height,
                                   width: (right - left) * frame.width, height: (bottom - top) * frame.height)
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)

                        Path { p in
                            p.addRect(frame)
                            p.addRect(r)
                        }
                        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))

                        Rectangle().stroke(Theme.signal, lineWidth: 2)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)

                        // Edge handles
                        handle(horizontal: true).position(x: r.midX, y: r.minY)
                            .gesture(edgeDrag(frame) { s, d in top = clamp(s.top + d.height / frame.height, 0, bottom - minSpan) })
                        handle(horizontal: true).position(x: r.midX, y: r.maxY)
                            .gesture(edgeDrag(frame) { s, d in bottom = clamp(s.bottom + d.height / frame.height, top + minSpan, 1) })
                        if !verticalOnly {
                            handle(horizontal: false).position(x: r.minX, y: r.midY)
                                .gesture(edgeDrag(frame) { s, d in left = clamp(s.left + d.width / frame.width, 0, right - minSpan) })
                            handle(horizontal: false).position(x: r.maxX, y: r.midY)
                                .gesture(edgeDrag(frame) { s, d in right = clamp(s.right + d.width / frame.width, left + minSpan, 1) })
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("Use whole photo") { onDone(CGRect(x: 0, y: 0, width: 1, height: 1)) }
                        .buttonStyle(SignalButtonStyle(filled: false))
                    Button("Continue") {
                        onDone(verticalOnly ? CGRect(x: 0, y: top, width: 1, height: bottom - top)
                                            : CGRect(x: left, y: top, width: right - left, height: bottom - top))
                    }
                    .buttonStyle(SignalButtonStyle())
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .background(Theme.ground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                if let subtitle {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(title).font(.headline)
                            Text(subtitle).font(.caption2).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
            }
        }
    }

    private func handle(horizontal: Bool) -> some View {
        Capsule()
            .fill(Theme.signal)
            .frame(width: horizontal ? 54 : 10, height: horizontal ? 10 : 54)
            .overlay(Capsule().stroke(.black.opacity(0.4), lineWidth: 1))
            .padding(18)                       // larger touch target
            .contentShape(Rectangle())
    }

    private func edgeDrag(_ frame: CGRect,
                          _ update: @escaping ((top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat), CGSize) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if start == nil { start = (top, bottom, left, right) }
                if let s = start { update(s, v.translation) }
            }
            .onEnded { _ in start = nil }
    }

    private func fitted(_ size: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / max(size.width, 1), container.height / max(size.height, 1))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
}
