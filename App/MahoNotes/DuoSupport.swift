#if os(iOS)
import SwiftUI

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

/// iPhone Duo's fold, from a vertical `.division` reserved region.
struct DuoFold: Equatable, Sendable {
    /// x position of the hinge line (the region's center) in the global
    /// (window) coordinate space.
    var midX: CGFloat
    /// `true` while the device is partially open and the fold divides the inner
    /// display; `false` when it lies flat.
    var isActive: Bool
}

extension View {
    /// Reports iPhone Duo's vertical fold, or `nil` when there is none: every
    /// other device, Duo's outer display, and the tabletop pose, where the fold
    /// runs horizontally. Attach it to a view that spans the window (for
    /// example a `Color.clear` background with `.ignoresSafeArea()`) so the
    /// fold always lies inside the measured view.
    ///
    /// The region is queried with `.includeInactive`, so on Duo's inner display
    /// the value stays non-nil while the device lies flat and only `isActive`
    /// flips as it folds. Callers can rely on that to keep the same modifiers in
    /// place across fold changes instead of swapping view identity.
    func onDuoFoldChange(_ action: @escaping (DuoFold?) -> Void) -> some View {
        onGeometryChange(for: DuoFold?.self) { proxy in
            guard #available(iOS 27.1, *) else { return nil }
            let folds = proxy.reservedRegions(kind: .division, options: .includeInactive)
            // A fold that splits the view into left and right halves is taller
            // than it is wide; the tabletop pose gives a horizontal one.
            guard let fold = folds.first(where: { $0.frame.height > $0.frame.width }) else {
                return nil
            }
            // Region frames are in the proxy's local space; report the hinge in
            // global coordinates so other views can compare their own frames.
            let originX = proxy.frame(in: .global).minX
            return DuoFold(midX: originX + fold.frame.midX, isActive: fold.isActive)
        } action: { fold in
            action(fold)
        }
    }
}

/// Sizes the navigator (content) column of a split view so the columns before
/// the detail end exactly at iPhone Duo's fold while the device is partially
/// open: navigator (plus the vault rail when the system shows it) on one half
/// of the inner display, the note on the other — the even split Apple's own
/// split views (Notes, Mail) switch to.
///
/// - `fold == nil` (every other device, Duo's outer display): no modifier, the
///   split view keeps its default widths.
/// - Fold present but flat: the navigator gets its usual ideal width.
/// - Fold active: min = ideal = max = distance from the navigator's leading
///   edge to the hinge line.
///
/// The navigator's leading edge is measured rather than derived from the
/// requested column visibility, because the system may hide the vault rail
/// (on the inner display at 951 pt it shows only navigator + detail). That
/// edge depends only on which columns precede the navigator, not on the
/// navigator's own width, so resizing it cannot feed back into the next
/// measurement.
///
/// The width modifier is applied through a single call in both Duo states so
/// folding changes only its values, never the column's view identity (which
/// would reset the navigator's scroll position and expanded collections).
struct FoldAlignedNavigatorWidth: ViewModifier {
    let fold: DuoFold?

    /// Navigator width on Duo's inner display while it lies flat.
    static let flatIdealWidth: CGFloat = 320

    /// The navigator's leading edge in global (window) coordinates.
    @State private var leadingX: CGFloat = 0

    func body(content: Content) -> some View {
        if let fold {
            let foldedWidth = max(fold.midX - leadingX, 0)
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minX
                } action: { minX in
                    leadingX = minX
                }
                .navigationSplitViewColumnWidth(
                    min: fold.isActive ? foldedWidth : nil,
                    ideal: fold.isActive ? foldedWidth : Self.flatIdealWidth,
                    max: fold.isActive ? foldedWidth : nil
                )
        } else {
            content
        }
    }
}
#endif
