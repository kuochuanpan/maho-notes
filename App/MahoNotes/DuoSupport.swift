#if os(iOS)
import SwiftUI
import os

// MARK: - iPhone Duo support
//
// iPhone Duo APIs ship in the iOS 27.1 SDK, while the app deploys to iOS 18, so
// every use goes through the helpers below behind `#available(iOS 27.1, *)`.
// On every other device (and on Duo in poses that keep horizontal bars) they
// report "no vertical bar" and "no fold", and the existing layouts render
// unchanged. Referencing these symbols also means the app no longer compiles
// with the iOS 27.0 SDK — intentionally: a 27.0-SDK build runs on Duo in a
// compatibility window that leaves an empty strip along the right edge of both
// displays (see decision #31).

/// Reads the edge where the system lays toolbars out vertically
/// (`EnvironmentValues.toolbarVerticalEdge`, iOS 27.1+) at this point in the
/// view hierarchy and hands it to `content`.
///
/// On iPhone Duo the status bar, navigation buttons, and toolbar items move into
/// a vertical bar on the trailing edge on the outer display and on the inner
/// display in landscape. The value is `nil` wherever bars stay horizontal: on
/// every other iPhone and iPad, and on Duo's inner display in portrait.
///
/// Read it where the toolbar it describes lives — inside the `NavigationStack`
/// or split-view column — because a split view only gives its trailing-most
/// column the vertical bar.
struct ToolbarVerticalEdgeReader<Content: View>: View {
    @ViewBuilder var content: (HorizontalEdge?) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            ToolbarVerticalEdgeReaderBody(content: content)
        } else {
            content(nil)
        }
    }
}

@available(iOS 27.1, *)
private struct ToolbarVerticalEdgeReaderBody<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let content: (HorizontalEdge?) -> Content

    var body: some View {
        content(verticalEdge)
    }
}

// MARK: - Hinge

/// Diagnostics for the Duo layout (hinge, fold, column width). Stream them with
/// Console.app on a Mac with the device attached, filtering on category "duo".
let duoLog = Logger(subsystem: "dev.pcca.maho-notes", category: "duo")

/// iPhone Duo's hinge, mirrored from `DeviceHinge` (iOS 27.1+).
struct DuoHinge: Equatable, Sendable {
    enum Status: String, Sendable {
        case closed, partiallyOpen, fullyOpen
    }

    var status: Status
    /// 180° when flat.
    var angleDegrees: Double

    /// The book pose: folded far enough that the two halves read as separate
    /// pages. The system reports `partiallyOpen` from about 125° all the way
    /// up to 175° (measured on the iOS 27.1 simulator), which includes "open,
    /// held in hand" angles, so this engages at `engageAngle` and only lets go
    /// above `releaseAngle` — the gap keeps a hand-held device hovering near
    /// the threshold from flipping the layout back and forth.
    func isBookFolded(wasFolded: Bool) -> Bool {
        guard status == .partiallyOpen else { return false }
        return angleDegrees <= (wasFolded ? Self.releaseAngle : Self.engageAngle)
    }

    static let engageAngle = 160.0
    static let releaseAngle = 170.0
}

extension View {
    /// Calls `action` with the hinge when the view appears and on every change;
    /// `nil` on devices without a hinge. During a fold this fires many times a
    /// second, so keep the work in `action` to comparing and storing values.
    ///
    /// Built on `onHingeChange`, which the system delivers on every fold change.
    /// The fold's reserved region, by contrast, only turns active once the
    /// hinge has settled (on the simulator, not at all while it moves), and
    /// geometry callbacks only run when something lays the view out again, so
    /// neither can be relied on to notice a hand-held fold by itself.
    func onDuoHingeChange(_ action: @escaping (DuoHinge?) -> Void) -> some View {
        modifier(DuoHingeObserver(action: action))
    }
}

private struct DuoHingeObserver: ViewModifier {
    let action: (DuoHinge?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { oldContext, newContext in
                let hinge = DuoHinge(newContext.hinge)
                if let hinge, hinge.status != DuoHinge(oldContext.hinge)?.status {
                    duoLog.info("hinge \(hinge.status.rawValue, privacy: .public) at \(hinge.angleDegrees, privacy: .public)°")
                }
                action(hinge)
            }
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private extension DuoHinge {
    init?(_ hinge: DeviceHinge?) {
        guard let hinge else { return nil }
        let status: Status
        if hinge.status == .closed {
            status = .closed
        } else if hinge.status == .partiallyOpen {
            status = .partiallyOpen
        } else {
            status = .fullyOpen
        }
        self.init(status: status, angleDegrees: hinge.angle.degrees)
    }
}

// MARK: - Fold

/// Where iPhone Duo's fold runs down a landscape window (book pose).
struct DuoFold: Equatable, Sendable {
    /// x position of the hinge line in the global (window) coordinate space.
    var midX: CGFloat
    /// The system reports the fold's `.division` region as active, i.e. the
    /// device is partially open and the fold divides the display.
    var isActive: Bool
    /// `midX` comes from a reserved region; `false` means the region was not
    /// reported and `midX` is the window's center, where the inner display's
    /// hinge runs whenever the app fills it.
    var isReported: Bool
}

extension View {
    /// Reports where a vertical fold crosses this view, or `nil` when there
    /// can't be one: the system reports only a horizontal fold (tabletop), or
    /// the view is taller than wide (outer display, inner display in portrait).
    /// Attach it to a view that spans the window (for example a `Color.clear`
    /// background with `.ignoresSafeArea()`) so the fold lies inside it.
    ///
    /// On devices without a hinge this still returns the window center for a
    /// landscape window; pair it with `onDuoHingeChange`, which is `nil` there.
    func onDuoFoldChange(_ action: @escaping (DuoFold?) -> Void) -> some View {
        onGeometryChange(for: DuoFold?.self) { proxy in
            // Region frames are in the proxy's local space; report the hinge in
            // global coordinates so other views can compare their own frames.
            let frame = proxy.frame(in: .global)
            if #available(iOS 27.1, *) {
                let folds = proxy.reservedRegions(kind: .division, options: .includeInactive)
                if !folds.isEmpty {
                    // A fold that splits the view into left and right halves is
                    // taller than it is wide.
                    guard let fold = folds.first(where: { $0.frame.height > $0.frame.width }) else {
                        return nil
                    }
                    return DuoFold(midX: frame.minX + fold.frame.midX, isActive: fold.isActive, isReported: true)
                }
            }
            guard frame.width > frame.height else { return nil }
            return DuoFold(midX: frame.midX, isActive: false, isReported: false)
        } action: { fold in
            if let fold {
                duoLog.info("fold x=\(fold.midX, privacy: .public) active=\(fold.isActive, privacy: .public) reported=\(fold.isReported, privacy: .public)")
            }
            action(fold)
        }
    }
}

// MARK: - Fold-aligned split view column

/// Sizes the navigator (content) column of a split view so the columns before
/// the detail end exactly at iPhone Duo's fold while the device is folded like
/// a book: navigator (plus the vault rail when the system shows it) on one half
/// of the inner display, the note on the other — the even split Apple's own
/// split views (Notes, Mail) switch to.
///
/// - `isEnabled == false` (every other device, Duo's outer display): no
///   modifier, the split view keeps its default widths.
/// - Enabled, `foldMidX == nil` (flat, or tabletop): the navigator gets
///   `flatIdealWidth` as its ideal; the split view lays it out at about 341 pt.
/// - Enabled with a fold: min = ideal = max = distance from the navigator's
///   leading edge to the hinge line.
///
/// The navigator's leading edge is measured rather than derived from the
/// requested column visibility, because the system may hide the vault rail
/// (on the inner display at 951 pt it shows only navigator + detail). That
/// edge depends only on which columns precede the navigator, not on the
/// navigator's own width, so resizing it cannot feed back into the next
/// measurement.
///
/// While enabled, the width modifier is applied through one call whether or
/// not the device is folded, so folding changes only its values, never the
/// column's view identity (which would reset the navigator's scroll position
/// and expanded collections).
struct FoldAlignedNavigatorWidth: ViewModifier {
    /// Whether the device has a hinge (iPhone Duo). Fixed for the lifetime of
    /// the view apart from the first hinge report.
    let isEnabled: Bool
    /// Global x of the hinge line while folded like a book, otherwise `nil`.
    let foldMidX: CGFloat?

    /// Navigator width on Duo's inner display while it lies flat.
    static let flatIdealWidth: CGFloat = 320

    /// The navigator's leading edge in global (window) coordinates.
    @State private var leadingX: CGFloat = 0

    func body(content: Content) -> some View {
        if isEnabled {
            let foldedWidth = foldMidX.map { max($0 - leadingX, 0) }
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minX
                } action: { minX in
                    leadingX = minX
                }
                .navigationSplitViewColumnWidth(
                    min: foldedWidth,
                    ideal: foldedWidth ?? Self.flatIdealWidth,
                    max: foldedWidth
                )
                .onChange(of: foldedWidth, initial: true) { _, width in
                    duoLog.info("navigator width \(width.map { "\($0)" } ?? "flat", privacy: .public) (leading edge \(leadingX, privacy: .public))")
                }
        } else {
            content
        }
    }
}
#endif
