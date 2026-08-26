import CoreGraphics

/// Fixed sizing policy for the menu-bar popover (R17).
///
/// The popover's logical canvas is fixed at 640×700 pt. The only adjustment
/// is one safety clamp applied while the popover is still hidden, right
/// before `show`: each dimension independently lowers to
/// `visibleFrame - 24` when the target screen cannot show the full canvas.
/// Nothing observed while the popover is on screen — tab switches, expanding
/// sections, arriving data, language or appearance changes, call phases —
/// may change the outer frame; pages scroll internally instead. A later
/// change of the screen's available area may shrink a shown popover once,
/// without animation, when it no longer fits.
struct PanelPresentationSpec: Equatable {
    /// Fixed popover width (R17: 520 → 640 so all nine tabs fit without
    /// truncation and tab switches cannot squeeze the content).
    static let popoverWidth: CGFloat = 640
    /// Fixed logical popover height; the pre-show screen clamp can only
    /// lower it.
    static let popoverHeight: CGFloat = 700
    /// Margin kept between the popover and the screen's visible frame.
    static let screenMargin: CGFloat = 24

    /// The single pre-show clamp (R17): width and height each
    /// `min(fixed, visibleFrame - 24)` independently; `nil` per-dimension
    /// falls back to that fixed value. Without a screen the fixed logical
    /// canvas applies.
    static func clampedSize(visibleFrame: CGRect?) -> CGSize {
        guard let visibleFrame else {
            return CGSize(width: popoverWidth, height: popoverHeight)
        }
        let width = visibleFrame.width.isFinite
            ? min(popoverWidth, visibleFrame.width - screenMargin)
            : popoverWidth
        let height = visibleFrame.height.isFinite
            ? min(popoverHeight, visibleFrame.height - screenMargin)
            : popoverHeight
        return CGSize(width: width, height: height)
    }
}
