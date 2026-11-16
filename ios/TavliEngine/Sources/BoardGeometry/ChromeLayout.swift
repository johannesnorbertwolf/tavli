import CoreGraphics

/// Safe-area insets in a SwiftUI-free form (mirrors `EdgeInsets`, layout direction
/// already resolved: `leading` is the left edge in left-to-right layouts).
public struct SafeAreaInsets: Equatable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = SafeAreaInsets()
}

/// Which chrome arrangement a screen uses (#109).
///
/// - `regular`: the iPad layout — a 280 pt side panel in landscape, a top bar plus
///   controls above the board in portrait, 8 pt around the board.
/// - `compactPortrait`: phone portrait — the board spans the full safe width,
///   anchored to the bottom of the safe area; compact chrome stacks above it.
/// - `compactLandscape`: phone landscape — the board spans the full safe height,
///   pinned to the leading safe edge; the chrome collapses into a rail beside it.
public enum ChromeMode: Equatable {
    case regular
    case compactPortrait
    case compactLandscape

    public var isCompact: Bool { self != .regular }
}

/// Pure layout metrics for the board screens (#109): given the window (container)
/// size and its safe-area insets, where the square board goes, where the chrome
/// goes, and how large the chrome type is. Views read their `GeometryReader` into
/// this one helper instead of branching on device type, so the iPhone/iPad split
/// lives in exactly one place.
///
/// A container whose **shorter side is below `compactThreshold`** (every iPhone, in
/// both orientations; never a full-screen iPad) gets a compact mode. The regular
/// mode reproduces the pre-#109 iPad layout exactly. All rects are in container
/// coordinates (origin = the window's top-left, safe area included).
public struct ChromeLayout: Equatable {
    // ── Regular (iPad) metrics — the values the layout used before #109 ─────────
    /// Padding around the board on every side.
    public static let regularBoardPadding: CGFloat = 8
    /// Width of the landscape chrome column.
    public static let regularPanelWidth: CGFloat = 280
    /// Trailing + vertical inset of the landscape chrome column.
    public static let regularPanelInset: CGFloat = 12
    /// Vertical padding of the portrait stack (board sits this far above the safe bottom).
    public static let regularPortraitPadding: CGFloat = 12

    // ── Compact (iPhone) metrics ────────────────────────────────────────────────
    /// Shorter container side below which the compact chrome is used (iPhones top
    /// out at 440 pt; the smallest iPad is 744 pt).
    public static let compactThreshold: CGFloat = 500
    /// Chrome type scale on a compact screen: ~2–3 pt off each `ChromeType` size.
    public static let compactFontScale: CGFloat = 0.86
    /// Gap between the board and the landscape rail.
    public static let compactRailGap: CGFloat = 8
    /// Trailing inset of the landscape rail (inside the safe area).
    public static let compactRailInset: CGFloat = 8
    /// The rail never gets narrower than this; the board shrinks instead.
    public static let compactMinRailWidth: CGFloat = 220
    /// Minimum chrome height kept above the board in compact portrait.
    public static let compactMinChromeHeight: CGFloat = 180

    public let mode: ChromeMode
    /// The safe area within the container.
    public let safeRect: CGRect
    /// The square board.
    public let boardRect: CGRect
    /// Where the chrome lives: the side panel / rail in landscape, the band above
    /// the board in portrait.
    public let panelRect: CGRect
    /// Padding the board keeps from its neighbours (8 regular, 0 compact).
    public let boardPadding: CGFloat

    public var isCompact: Bool { mode.isCompact }
    public var isLandscape: Bool { safeRect.width >= safeRect.height }
    public var boardSide: CGFloat { boardRect.width }
    /// Multiplier applied to every `ChromeType` size.
    public var fontScale: CGFloat { Self.fontScale(isCompact: isCompact) }

    public init(container: CGSize, safeArea: SafeAreaInsets = .zero) {
        let safe = CGRect(x: safeArea.leading,
                          y: safeArea.top,
                          width: max(0, container.width - safeArea.leading - safeArea.trailing),
                          height: max(0, container.height - safeArea.top - safeArea.bottom))
        safeRect = safe
        let landscape = safe.width >= safe.height

        guard Self.isCompact(container: container) else {
            boardPadding = Self.regularBoardPadding
            let pad = Self.regularBoardPadding
            if landscape {
                // HStack { board.padding(8) ; panel(280).padding(.vertical/.trailing, 12) }:
                // the board column is what the panel leaves, the square centred
                // vertically and pinned to the leading edge.
                let column = safe.width - Self.regularPanelWidth - Self.regularPanelInset
                let side = max(0, min(column - 2 * pad, safe.height - 2 * pad))
                boardRect = CGRect(x: safe.minX + pad,
                                   y: safe.minY + pad + (safe.height - 2 * pad - side) / 2,
                                   width: side, height: side)
                panelRect = CGRect(x: safe.maxX - Self.regularPanelInset - Self.regularPanelWidth,
                                   y: safe.minY + Self.regularPanelInset,
                                   width: Self.regularPanelWidth,
                                   height: max(0, safe.height - 2 * Self.regularPanelInset))
            } else {
                // VStack(bar, Spacer, controls, board.padding(.horizontal, 8)).padding(.vertical, 12):
                // full-width square anchored to the bottom.
                let side = max(0, safe.width - 2 * pad)
                let y = safe.maxY - Self.regularPortraitPadding - side
                boardRect = CGRect(x: safe.minX + pad, y: y, width: side, height: side)
                let top = safe.minY + Self.regularPortraitPadding
                panelRect = CGRect(x: safe.minX, y: top, width: safe.width,
                                   height: max(0, y - Self.regularPortraitPadding - top))
            }
            mode = .regular
            return
        }

        boardPadding = 0
        if landscape {
            // Full safe height, leading edge; the rail takes the rest of the width.
            let maxSide = safe.width - Self.compactRailGap - Self.compactRailInset - Self.compactMinRailWidth
            let side = max(0, min(safe.height, maxSide))
            boardRect = CGRect(x: safe.minX, y: safe.minY + (safe.height - side) / 2,
                               width: side, height: side)
            let railX = boardRect.maxX + Self.compactRailGap
            panelRect = CGRect(x: railX, y: safe.minY,
                               width: max(0, safe.maxX - Self.compactRailInset - railX),
                               height: safe.height)
            mode = .compactLandscape
        } else {
            // Full safe width, bottom of the safe area; the chrome stacks above.
            let side = max(0, min(safe.width, safe.height - Self.compactMinChromeHeight))
            boardRect = CGRect(x: safe.minX + (safe.width - side) / 2, y: safe.maxY - side,
                               width: side, height: side)
            panelRect = CGRect(x: safe.minX, y: safe.minY, width: safe.width,
                               height: max(0, boardRect.minY - safe.minY))
            mode = .compactPortrait
        }
    }

    /// Whether a container this size uses the compact chrome.
    public static func isCompact(container: CGSize) -> Bool {
        min(container.width, container.height) < compactThreshold
    }

    /// The chrome type scale for a screen of this size (constant per device: the
    /// shorter side never changes with rotation).
    public static func fontScale(forScreen size: CGSize) -> CGFloat {
        fontScale(isCompact: isCompact(container: size))
    }

    private static func fontScale(isCompact: Bool) -> CGFloat {
        isCompact ? compactFontScale : 1
    }
}
