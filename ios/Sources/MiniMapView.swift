// SPDX-License-Identifier: GPL-2.0-or-later
import QuartzCore
import UIKit

/// Pan and zoom of the Windows picture inside the canvas, drawn by the presenter (devices/fb_metal.m).
///
/// The picture as fitted to the view ("fitted", in view points) is scaled by `zoom` about the view's centre
/// and then moved by `offset`. The on-screen keyboard covers the bottom of the view (`keyboardOverlap`):
/// the picture keeps its scale and slides up instead of shrinking, so what has to be seen (the caret, the
/// tap point) sits above the keys.
final class ViewportController {
    weak var view: UIView?
    /// Called after every change (the mini-maps redraw).
    var onChange: (() -> Void)?

    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGPoint = .zero
    /// The bottom part of the view under the keyboard and its key bar, in points.
    private(set) var keyboardOverlap: CGFloat = 0

    static let maxZoom: CGFloat = 4
    /// Viewport zoom follows the pointer and the caret only once they come this close to an edge (a
    /// fraction of the visible size on each side: 15% + 15% = a 30% edge band).
    static let followBand: CGFloat = 0.15

    private var link: CADisplayLink?
    private var animFrom = (zoom: CGFloat(1), offset: CGPoint.zero)
    private var animTo = (zoom: CGFloat(1), offset: CGPoint.zero)
    private var animStart: CFTimeInterval = 0
    private var animDuration: CFTimeInterval = 0

    var isZoomed: Bool { zoom > 1.01 }
    var isPanned: Bool { isZoomed || abs(offset.x) > 0.5 || abs(offset.y) > 0.5 }

    private var bounds: CGRect { view?.bounds ?? .zero }
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// The part of the view not covered by the keyboard.
    var visibleRect: CGRect {
        var r = bounds
        r.size.height = max(40, r.height - keyboardOverlap)
        return r
    }

    /// Windows' screen size in pixels (0 x 0 before it draws).
    var framebufferSize: CGSize {
        CGSize(width: CGFloat(WinIOSBridge.shared.framebufferWidth), height: CGFloat(WinIOSBridge.shared.framebufferHeight))
    }

    /// The picture fitted into the view (aspect kept, centred), unzoomed, in view points.
    var fittedRect: CGRect {
        let b = bounds
        let fb = framebufferSize
        guard fb.width > 0, fb.height > 0, b.width > 0, b.height > 0 else { return b }
        let s = min(b.width / fb.width, b.height / fb.height)
        let w = fb.width * s, h = fb.height * s
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    /// Where the picture is shown now.
    var displayedRect: CGRect { project(fittedRect) }

    // MARK: mapping

    /// A point of the unzoomed picture -> where it is on screen.
    func project(_ p: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (p.x - center.x) * zoom + offset.x, y: center.y + (p.y - center.y) * zoom + offset.y)
    }

    func project(_ r: CGRect) -> CGRect {
        let a = project(r.origin)
        return CGRect(x: a.x, y: a.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// A point on screen -> the point of the unzoomed picture under it (touches go to Windows through this).
    func unproject(_ q: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (q.x - center.x - offset.x) / zoom, y: center.y + (q.y - center.y - offset.y) / zoom)
    }

    func unproject(_ r: CGRect) -> CGRect {
        let a = unproject(r.origin)
        return CGRect(x: a.x, y: a.y, width: r.width / zoom, height: r.height / zoom)
    }

    /// A rectangle in Windows' pixels -> the unzoomed picture's view points.
    func pictureRect(fromFramebuffer r: CGRect, framebuffer: CGSize? = nil) -> CGRect {
        let fb = framebuffer ?? framebufferSize
        let f = fittedRect
        guard fb.width > 0, fb.height > 0 else { return .null }
        return CGRect(x: f.minX + r.minX / fb.width * f.width, y: f.minY + r.minY / fb.height * f.height,
                      width: r.width / fb.width * f.width, height: r.height / fb.height * f.height)
    }

    /// The part of Windows' screen that can be seen, as fractions (0...1) of it.
    var visibleFraction: CGRect {
        let f = fittedRect
        guard f.width > 0, f.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let v = unproject(visibleRect).intersection(f)
        guard !v.isNull else { return .zero }
        return CGRect(x: (v.minX - f.minX) / f.width, y: (v.minY - f.minY) / f.height,
                      width: v.width / f.width, height: v.height / f.height)
    }

    // MARK: changes

    /// The keyboard (and its bar) now covers `overlap` points at the bottom: slide the picture so `keep`
    /// (unzoomed picture points: the caret or the tap point) stays above it.
    func setKeyboardOverlap(_ overlap: CGFloat, keep: CGRect?, duration: TimeInterval) {
        keyboardOverlap = max(0, overlap)
        var t = clamped(zoom: zoom, offset: offset)
        if let keep, !keep.isNull, overlap > 0 {
            t = revealed(keep, zoom: zoom, offset: t, band: nil)
        }
        go(zoom: zoom, offset: t, duration: duration)
    }

    /// Brings `rect` (unzoomed picture points) into the visible part. band: keep it this far (a fraction of
    /// the visible size) from the edges, for following the pointer; nil: a small fixed margin, for the caret.
    func reveal(_ rect: CGRect, band: CGFloat? = nil, duration: TimeInterval = 0.18) {
        guard !rect.isNull, bounds.width > 0 else { return }
        let t = revealed(rect, zoom: zoom, offset: offset, band: band)
        if abs(t.x - offset.x) < 0.5 && abs(t.y - offset.y) < 0.5 { return }
        go(zoom: zoom, offset: t, duration: duration)
    }

    func pan(by d: CGPoint) {
        stopAnimation()
        apply(zoom: zoom, offset: clamped(zoom: zoom, offset: CGPoint(x: offset.x + d.x, y: offset.y + d.y)))
    }

    /// Zoom to z, keeping the picture point under `anchor` (a point on screen) where it is.
    func setZoom(_ z: CGFloat, anchor: CGPoint, duration: TimeInterval = 0) {
        let nz = min(Self.maxZoom, max(1, z))
        let p = unproject(anchor)
        let t = CGPoint(x: anchor.x - center.x - (p.x - center.x) * nz, y: anchor.y - center.y - (p.y - center.y) * nz)
        go(zoom: nz, offset: clamped(zoom: nz, offset: t), duration: duration)
    }

    /// Centres the visible part on `p` (unzoomed picture points), as far as the picture allows.
    func centre(on p: CGPoint, duration: TimeInterval = 0.2) {
        let v = visibleRect
        let t = CGPoint(x: v.midX - center.x - (p.x - center.x) * zoom, y: v.midY - center.y - (p.y - center.y) * zoom)
        go(zoom: zoom, offset: clamped(zoom: zoom, offset: t), duration: duration)
    }

    func resetZoom(duration: TimeInterval = 0.22) {
        go(zoom: 1, offset: clamped(zoom: 1, offset: .zero), duration: duration)
    }

    /// The view changed size (rotation, fold) or Windows its resolution: keep the transform valid.
    func layoutChanged() {
        stopAnimation()
        apply(zoom: zoom, offset: clamped(zoom: zoom, offset: offset))
    }

    // MARK: internals

    /// Where the picture may be: along an axis where it is larger than the visible part it covers it fully;
    /// where it is smaller it is centred in the visible part (above the keyboard).
    private func clamped(zoom z: CGFloat, offset t: CGPoint) -> CGPoint {
        let f = fittedRect
        let v = visibleRect
        let c = center
        func axis(_ fMin: CGFloat, _ fSize: CGFloat, _ c: CGFloat, _ vMin: CGFloat, _ vSize: CGFloat, _ t: CGFloat) -> CGFloat {
            let size = fSize * z
            let base = c + (fMin - c) * z // where the picture's edge is with no offset
            var lo: CGFloat, hi: CGFloat
            if size >= vSize - 0.5 {
                lo = vMin + vSize - size
                hi = vMin
            } else {
                lo = vMin + (vSize - size) / 2
                hi = lo
            }
            return min(hi, max(lo, base + t)) - base
        }
        return CGPoint(x: axis(f.minX, f.width, c.x, v.minX, v.width, t.x),
                       y: axis(f.minY, f.height, c.y, v.minY, v.height, t.y))
    }

    private func revealed(_ rect: CGRect, zoom z: CGFloat, offset t0: CGPoint, band: CGFloat?) -> CGPoint {
        let v = visibleRect
        let c = center
        let r = CGRect(x: c.x + (rect.minX - c.x) * z + t0.x, y: c.y + (rect.minY - c.y) * z + t0.y,
                       width: rect.width * z, height: rect.height * z)
        let inset: UIEdgeInsets
        if let band {
            inset = UIEdgeInsets(top: v.height * band, left: v.width * band, bottom: v.height * band, right: v.width * band)
        } else {
            inset = UIEdgeInsets(top: 8, left: 12, bottom: 24, right: 12) // the caret: 24 pt above the key bar
        }
        let area = v.inset(by: inset)
        var t = t0
        if r.width <= area.width {
            if r.minX < area.minX { t.x += area.minX - r.minX } else if r.maxX > area.maxX { t.x -= r.maxX - area.maxX }
        }
        if r.height <= area.height {
            if r.maxY > area.maxY { t.y -= r.maxY - area.maxY } else if r.minY < area.minY { t.y += area.minY - r.minY }
        } else {
            t.y += area.minY - r.minY // taller than the space: its top
        }
        return clamped(zoom: z, offset: t)
    }

    private func go(zoom z: CGFloat, offset t: CGPoint, duration: TimeInterval) {
        if duration <= 0 || view?.window == nil || UIAccessibility.isReduceMotionEnabled {
            stopAnimation()
            apply(zoom: z, offset: t)
            return
        }
        animFrom = (zoom, offset)
        animTo = (z, t)
        animStart = CACurrentMediaTime()
        animDuration = duration
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(step))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    @objc private func step() {
        let k = min(1, (CACurrentMediaTime() - animStart) / max(0.01, animDuration))
        let e = CGFloat(1 - pow(1 - k, 3)) // ease out
        apply(zoom: animFrom.zoom + (animTo.zoom - animFrom.zoom) * e,
              offset: CGPoint(x: animFrom.offset.x + (animTo.offset.x - animFrom.offset.x) * e,
                              y: animFrom.offset.y + (animTo.offset.y - animFrom.offset.y) * e))
        if k >= 1 { stopAnimation() }
    }

    private func stopAnimation() {
        link?.invalidate()
        link = nil
    }

    private func apply(zoom z: CGFloat, offset t: CGPoint) {
        zoom = z
        offset = t
        let b = bounds
        if b.width > 0, b.height > 0 {
            WinIOSBridge.shared.setViewZoom(Double(z), translateX: Double(t.x / b.width), y: Double(t.y / b.height))
        }
        onChange?()
    }
}

/// The whole Windows screen in small: a picture of it (refreshed every few seconds while shown), the part
/// the canvas shows (a rectangle), the pointer (a dot) and the caret (a bar). Drag to pan, tap to centre
/// there, double-tap to go back to the caret, touch and hold to zoom back out.
final class MiniMapView: UIView {
    weak var viewport: ViewportController?
    /// The caret, in Windows' pixels (from the focus agent); nil when unknown.
    var caretFramebufferRect: CGRect? { didSet { setNeedsLayout() } }
    /// Double-tap: back to the caret (the canvas decides what that is).
    var onReturnToCaret: (() -> Void)?

    private let imageLayer = CALayer()
    private let viewLayer = CAShapeLayer()
    private let pointerLayer = CAShapeLayer()
    private let caretLayer = CALayer()
    private var refreshTimer: Timer?
    private var dragStart: CGPoint?
    /// HV_MINIMAP_THUMB=0 (Documents/env.txt): no picture, only the outline (saves the screenshot work).
    private static var thumbnails: Bool {
        guard let v = getenv("HV_MINIMAP_THUMB") else { return true }
        return String(cString: v) != "0"
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.10, alpha: 0.92)
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        clipsToBounds = true
        imageLayer.contentsGravity = .resize
        imageLayer.opacity = 0.85
        layer.addSublayer(imageLayer)
        viewLayer.fillColor = UIColor(white: 1, alpha: 0.12).cgColor
        viewLayer.strokeColor = UIColor.white.cgColor
        viewLayer.lineWidth = 1.5
        layer.addSublayer(viewLayer)
        caretLayer.backgroundColor = UIColor.systemYellow.cgColor
        caretLayer.isHidden = true
        layer.addSublayer(caretLayer)
        pointerLayer.fillColor = UIColor.white.cgColor
        pointerLayer.strokeColor = UIColor.black.cgColor
        pointerLayer.lineWidth = 0.75
        layer.addSublayer(pointerLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        addGestureRecognizer(pan)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.5
        addGestureRecognizer(hold)

        isAccessibilityElement = true
        accessibilityLabel = L("屏幕缩略图", "Screen map")
        accessibilityHint = L("上下轻扫可上下移动画面。连按两下回到光标。", "Swipe up or down to move the picture. Double-tap to go back to the cursor.")
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The size this map wants for a given height: Windows' screen shape.
    func preferredWidth(forHeight h: CGFloat) -> CGFloat {
        let fb = viewport?.framebufferSize ?? .zero
        let aspect = fb.width > 0 && fb.height > 0 ? fb.width / fb.height : 1.5
        return (h * min(2.2, max(0.45, aspect))).rounded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard window != nil else { return }
        refreshPicture()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private var ticks = 0
    private func tick() {
        guard window != nil, !isHidden, alpha > 0.01 else { return }
        ticks += 1
        setNeedsLayout() // the pointer moves
        if ticks % 12 == 0 { refreshPicture() } // the picture: every 3 s
    }

    func refreshPicture() {
        guard Self.thumbnails, window != nil, !isHidden else { return }
        let px = Int(max(bounds.width, bounds.height) * (window?.screen.scale ?? 2))
        WinIOSBridge.shared.makeScreenThumbnailMaxPixels(max(64, px)) { [weak self] image in
            guard let self, let image else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.imageLayer.contents = image
            CATransaction.commit()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        let b = bounds
        let v = viewport?.visibleFraction ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let r = CGRect(x: b.minX + v.minX * b.width, y: b.minY + v.minY * b.height,
                       width: v.width * b.width, height: v.height * b.height).insetBy(dx: 0.75, dy: 0.75)
        viewLayer.path = UIBezierPath(roundedRect: r, cornerRadius: 2).cgPath
        let px = CGFloat(PointerController.shared.cursorX) * b.width
        let py = CGFloat(PointerController.shared.cursorY) * b.height
        pointerLayer.path = UIBezierPath(ovalIn: CGRect(x: px - 2.5, y: py - 2.5, width: 5, height: 5)).cgPath
        let fb = viewport?.framebufferSize ?? .zero
        if let c = caretFramebufferRect, fb.width > 0, fb.height > 0 {
            caretLayer.isHidden = false
            caretLayer.frame = CGRect(x: c.minX / fb.width * b.width - 1, y: c.minY / fb.height * b.height,
                                      width: 2, height: max(3, c.height / fb.height * b.height))
        } else {
            caretLayer.isHidden = true
        }
        CATransaction.commit()
        accessibilityValue = String(format: L("显示 %.0f%%，从顶部往下 %.0f%%", "Showing %.0f%%, %.0f%% from the top"),
                                    v.width * v.height * 100, v.minY * 100)
    }

    /// A point of the map -> the unzoomed picture point it stands for.
    private func picturePoint(_ p: CGPoint) -> CGPoint? {
        guard let vp = viewport, bounds.width > 0, bounds.height > 0 else { return nil }
        let f = vp.fittedRect
        return CGPoint(x: f.minX + p.x / bounds.width * f.width, y: f.minY + p.y / bounds.height * f.height)
    }

    @objc private func onPan(_ gr: UIPanGestureRecognizer) {
        guard let vp = viewport, bounds.width > 0, bounds.height > 0 else { return }
        let t = gr.translation(in: self)
        gr.setTranslation(.zero, in: self)
        // the rectangle moves with the finger: the picture the other way, scaled up to the canvas
        let f = vp.fittedRect
        vp.pan(by: CGPoint(x: -t.x / bounds.width * f.width * vp.zoom, y: -t.y / bounds.height * f.height * vp.zoom))
        setNeedsLayout()
    }

    @objc private func onTap(_ gr: UITapGestureRecognizer) {
        guard let p = picturePoint(gr.location(in: self)) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        viewport?.centre(on: p)
    }

    @objc private func onDoubleTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onReturnToCaret?()
    }

    @objc private func onHold(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        viewport?.resetZoom()
    }

    override func accessibilityIncrement() {
        // "up": towards the top of the screen
        guard let vp = viewport else { return }
        vp.pan(by: CGPoint(x: 0, y: vp.visibleRect.height * 0.5))
    }

    override func accessibilityDecrement() {
        guard let vp = viewport else { return }
        vp.pan(by: CGPoint(x: 0, y: -vp.visibleRect.height * 0.5))
    }
}
