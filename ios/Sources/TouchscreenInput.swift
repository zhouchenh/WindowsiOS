// SPDX-License-Identifier: GPL-2.0-or-later
import QuartzCore
import UIKit

/// Multi-touch mode: the fingers on the Windows screen go to Windows' own touch screen (the USB touch screen
/// on the xHCI's port 3, driven by Windows' inbox HID touch driver) as touch contacts, so Windows does its own
/// taps, press-and-hold, pinch, pan with inertia and edge and multi-finger gestures.
///
/// One tracker per canvas. It gives each finger a contact id (the lowest free one, 0...9), sends one frame per
/// UIKit callback with every finger Windows has down, sends a lifting finger once with tip 0, and keeps the
/// rest from Windows:
/// - a finger that lands more than 16 pt outside the picture stays with the app (one within 16 pt of it is
///   clamped to its edge, so Windows' edge swipes still start at the edge);
/// - a new finger is held back for 70 ms before Windows sees it: when a third finger lands on the zoomed
///   picture or a fourth one anywhere, the app takes the gesture back (MetalCanvasUIView) and fingers held
///   back were never in Windows; fingers already down are cancelled (tip 0 with confidence 0: not a tap);
/// - while the app's edge swipes are on (immersive), a finger that lands at the left or right edge of the
///   window is held back up to 0.3 s or 48 pt of travel: if the app's edge swipe takes it (the touch is
///   cancelled) Windows never sees it.
/// A finger held back that lifts is sent as a quick tap (down, then up), with every other finger held back
/// going down with it, so a two-finger tap stays one gesture.
@MainActor
final class TouchscreenTracker {
    /// A point on Windows' screen (0...1, clamped) and how far outside the picture it was, in screen points.
    struct Mapped {
        var x: Double
        var y: Double
        var outside: CGFloat
    }

    /// The canvas's mapping (viewport pan and zoom, the fitted picture).
    var map: (CGPoint) -> Mapped = { _ in Mapped(x: 0, y: 0, outside: 0) }

    static let holdBack: CFTimeInterval = 0.07
    static let edgeHold: CFTimeInterval = 0.3
    static let edgeTravel: CGFloat = 48
    static let edgeZone: CGFloat = 24
    static let outsideLimit: CGFloat = 16

    private enum State { case heldBack, down, ignored }

    private final class Contact {
        let id: UInt8
        var state: State
        let start: CGPoint
        let startMapped: Mapped
        var current: Mapped
        let releaseAt: CFTimeInterval
        let atEdge: Bool

        init(id: UInt8, state: State, start: CGPoint, mapped: Mapped, releaseAt: CFTimeInterval, atEdge: Bool) {
            self.id = id
            self.state = state
            self.start = start
            startMapped = mapped
            current = mapped
            self.releaseAt = releaseAt
            self.atEdge = atEdge
        }
    }

    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var releaseWork: DispatchWorkItem?

    /// A gesture starts (its first finger landed): anything left from the last one is cancelled in Windows.
    func beginGesture() {
        if contacts.values.contains(where: { $0.state == .down }) { WinIOSBridge.shared.cancelAllTouchContacts() }
        contacts.removeAll()
        releaseWork?.cancel()
        releaseWork = nil
    }

    /// The gesture's last finger lifted.
    func endGesture() {
        beginGesture()
    }

    func began(_ touches: [UITouch], in view: UIView, edgeSwipes: Bool) {
        let now = CACurrentMediaTime()
        let width = view.window?.bounds.width ?? 0
        for t in touches {
            let key = ObjectIdentifier(t)
            guard contacts[key] == nil else { continue }
            let p = t.location(in: view)
            let m = map(p)
            guard m.outside <= Self.outsideLimit, let id = freeId() else {
                contacts[key] = Contact(id: 0, state: .ignored, start: p, mapped: m, releaseAt: now, atEdge: false)
                continue
            }
            let wx = t.location(in: nil).x
            let atEdge = edgeSwipes && width > 0 && (wx < Self.edgeZone || wx > width - Self.edgeZone)
            contacts[key] = Contact(id: id, state: .heldBack, start: p, mapped: m,
                                    releaseAt: now + (atEdge ? Self.edgeHold : Self.holdBack), atEdge: atEdge)
        }
        scheduleRelease()
    }

    func moved(_ touches: Set<UITouch>, in view: UIView) {
        var changed = false
        var due: [Contact] = []
        for t in touches {
            guard let c = contacts[ObjectIdentifier(t)], c.state != .ignored else { continue }
            let p = t.location(in: view)
            c.current = map(p)
            if c.state == .down {
                changed = true
            } else if c.atEdge && hypot(p.x - c.start.x, p.y - c.start.y) > Self.edgeTravel {
                due.append(c) // the app's edge swipe did not take it
            }
        }
        if !due.isEmpty {
            putDown(due)
            changed = true
        }
        if changed { send() }
    }

    func ended(_ touches: Set<UITouch>, cancelled: Bool) {
        var ending: [ObjectIdentifier] = []
        var tapped = false
        for t in touches {
            let key = ObjectIdentifier(t)
            guard let c = contacts[key] else { continue }
            switch c.state {
            case .ignored:
                contacts.removeValue(forKey: key)
            case .heldBack:
                if cancelled {
                    contacts.removeValue(forKey: key) // e.g. the app's edge swipe took it: Windows never saw it
                } else {
                    tapped = true
                    ending.append(key)
                }
            case .down:
                ending.append(key)
            }
        }
        if tapped {
            // A finger held back lifted: it and every other one held back go down now, where they landed.
            putDown(contacts.values.filter { $0.state == .heldBack })
        }
        let lifting = ending.compactMap { contacts.removeValue(forKey: $0) }.sorted { $0.id < $1.id }
        if !lifting.isEmpty {
            send(extra: lifting.map {
                WinIOSTouchContact(contactId: $0.id, tip: 0, confidence: cancelled ? 0 : 1, x: $0.current.x, y: $0.current.y)
            })
        }
        scheduleRelease()
    }

    /// The app takes the gesture back (or the view reshapes, the mode changes, the app leaves): every finger
    /// Windows has is cancelled, and none of the fingers still down goes to Windows any more.
    func cancelAll() {
        releaseWork?.cancel()
        releaseWork = nil
        for c in contacts.values { c.state = .ignored }
        WinIOSBridge.shared.cancelAllTouchContacts()
    }

    // MARK: -

    private func freeId() -> UInt8? {
        let used = Set(contacts.values.filter { $0.state != .ignored }.map(\.id))
        return (0..<UInt8(10)).first { !used.contains($0) }
    }

    /// Fingers held back go down: one frame with them where they landed (the others where they are now).
    private func putDown(_ list: [Contact]) {
        guard !list.isEmpty else { return }
        for c in list { c.state = .down }
        send(startOf: Set(list.map(\.id)))
    }

    /// One frame: every finger Windows has down, in id order (so a frame that only moves them is merged with
    /// the one before while Windows has not read it), then `extra` (lifts).
    private func send(startOf: Set<UInt8> = [], extra: [WinIOSTouchContact] = []) {
        var frame: [WinIOSTouchContact] = []
        for c in contacts.values.filter({ $0.state == .down }).sorted(by: { $0.id < $1.id }) {
            let m = startOf.contains(c.id) ? c.startMapped : c.current
            frame.append(WinIOSTouchContact(contactId: c.id, tip: 1, confidence: 1, x: m.x, y: m.y))
        }
        frame += extra
        guard !frame.isEmpty else { return }
        frame.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { WinIOSBridge.shared.sendTouchContacts(base, count: buf.count) }
        }
    }

    private func scheduleRelease() {
        releaseWork?.cancel()
        releaseWork = nil
        guard let next = contacts.values.filter({ $0.state == .heldBack }).map(\.releaseAt).min() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.releaseWork = nil
            let now = CACurrentMediaTime() + 0.001
            self.putDown(self.contacts.values.filter { $0.state == .heldBack && $0.releaseAt <= now })
            self.scheduleRelease()
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next - CACurrentMediaTime()), execute: work)
    }
}
