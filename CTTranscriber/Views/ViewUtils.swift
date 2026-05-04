import AppKit

enum ViewUtils {
    static func findOutlineView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSOutlineView { return view }
        for subview in view.subviews {
            if let found = findOutlineView(in: subview) { return found }
        }
        return nil
    }
}
