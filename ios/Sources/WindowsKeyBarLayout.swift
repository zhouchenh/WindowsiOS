// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics

/// Where WindowsKeyBar's capsules go at a given width. Pure arithmetic (no UIKit), so it can be checked
/// away from the app.
///
///   (Esc) [app keys row] (Tab Ctrl Alt Shift Win) [arrows row] ... (Shortcuts) (hide) [map]
///
/// Rules: nothing overlaps; a scrolling row is never narrower than two keys and half of the next (a 1-key
/// strip with a half-cut key in its fade reads as broken); the regular bar (42-point keys and the map) only
/// where it still holds such a row, else the compact one (34-point keys). With no room for the app keys of
/// their own they follow the arrows in one row; with no room for even that row, the row goes and its keys
/// are in the Shortcuts menu. Keys get narrower than 34 points only where Esc, the modifiers, Shortcuts and
/// hide would not fit otherwise.
struct KeyBarLayout: Equatable {
    var compact = true
    /// Key width, the gap between capsules and the inset of the keys in their capsule.
    var kw: CGFloat = 34
    var gap: CGFloat = 5
    var pad: CGFloat = 3
    var escX: CGFloat = 0
    /// The app keys' own row (0 wide: merged into the arrows row, or no row).
    var leadX: CGFloat = 0, leadW: CGFloat = 0
    var modsX: CGFloat = 0
    /// The scrolling row (0 wide: no row).
    var arrowsX: CGFloat = 0, arrowsW: CGFloat = 0
    var paletteX: CGFloat = 0
    var hideX: CGFloat = 0
    var mapX: CGFloat = 0, mapW: CGFloat = 0
    /// The app keys follow the arrows in one row.
    var merged = false
    /// No room for a row: the arrows and app keys are in the Shortcuts menu.
    var rowHidden = false

    /// A capsule of n keys.
    func capW(_ n: Int) -> CGFloat { CGFloat(n) * kw + 2 * pad }
    /// The app keys' content: (Start, Search, Task View) gap (Undo, Redo).
    var leadContent: CGFloat { capW(3) + gap + capW(2) }
    /// The narrowest a scrolling row may be.
    var minRow: CGFloat { capW(2) + kw / 2 }
    /// Where a notice may lie between Esc and Shortcuts (over the modifiers too).
    var wideNoticeX: CGFloat { escX + capW(1) + gap }
    var wideNoticeW: CGFloat { max(0, paletteX - gap - wideNoticeX) }

    /// - Parameters:
    ///   - width: the bar's width; insetLeft/insetRight: its safe-area insets.
    ///   - mapPreferred: the map's width at the regular height (MiniMapView.preferredWidth).
    ///   - arrowCount: keys in the arrows row.
    static func make(width: CGFloat, insetLeft: CGFloat, insetRight: CGFloat, mapPreferred: CGFloat,
                     arrowCount: Int) -> KeyBarLayout {
        if width >= 560, let l = attempt(compact: false, width: width, insetLeft: insetLeft, insetRight: insetRight,
                                         mapPreferred: mapPreferred, arrowCount: arrowCount) {
            return l
        }
        return attempt(compact: true, width: width, insetLeft: insetLeft, insetRight: insetRight,
                       mapPreferred: 0, arrowCount: arrowCount)!
    }

    /// nil: the regular bar holds no row of minRow.
    private static func attempt(compact: Bool, width: CGFloat, insetLeft: CGFloat, insetRight: CGFloat,
                                mapPreferred: CGFloat, arrowCount: Int) -> KeyBarLayout? {
        var l = KeyBarLayout()
        l.compact = compact
        l.kw = compact ? 34 : 42
        l.gap = compact ? 5 : 9
        l.mapW = compact ? 0 : mapPreferred
        let left = insetLeft + (compact ? 4 : 8)
        let right = width - insetRight - (compact ? 4 : 8)
        let span = max(0, right - left)

        let arrowContent = l.capW(arrowCount)
        let fixed = l.capW(1) /* esc */ + l.capW(5) /* mods */ + l.capW(1) /* palette */ + l.capW(1) /* hide */ + l.mapW
        // gaps between the capsules with both rows (and the map); one row has one gap fewer
        let both = span - fixed - l.gap * (compact ? 5 : 6)
        let one = both + l.gap
        if both >= l.leadContent + arrowContent {
            l.leadW = l.leadContent
            l.arrowsW = arrowContent
        } else if both >= 2 * l.minRow {
            l.arrowsW = min(arrowContent, max(l.minRow, both - l.leadContent))
            l.leadW = min(l.leadContent, both - l.arrowsW)
        } else if one >= l.minRow {
            l.merged = true // no room for the app keys of their own (a phone): they follow the arrows
            l.arrowsW = min(arrowContent + l.gap + l.leadContent, one)
        } else {
            if !compact { return nil }
            l.merged = true
            l.rowHidden = true
            // Esc, the modifiers, Shortcuts, hide: 8 keys in 4 capsules and 3 gaps, narrower only if they must
            let fit = ((span - 4 * 2 * l.pad - 3 * l.gap) / 8).rounded(.down)
            l.kw = max(24, min(l.kw, fit))
        }

        var x = left
        l.escX = x
        x += l.capW(1) + l.gap
        if !l.merged {
            l.leadX = x
            x += l.leadW + l.gap
        } else {
            l.leadX = x
            l.leadW = 0
        }
        l.modsX = x
        x += l.capW(5) + l.gap
        l.arrowsX = x
        if l.rowHidden { l.arrowsW = 0 }

        var rx = right
        if !compact {
            rx -= l.mapW
            l.mapX = rx
            rx -= l.gap
        }
        rx -= l.capW(1)
        l.hideX = rx
        rx -= l.gap + l.capW(1)
        l.paletteX = rx
        return l
    }
}
