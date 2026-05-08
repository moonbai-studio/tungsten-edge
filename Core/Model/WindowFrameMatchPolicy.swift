import CoreGraphics
import Foundation

struct WindowFrameMatchPolicy {
    static let tolerance: CGFloat = 24

    static func areClose(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = Self.tolerance
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    static func score(_ lhs: CGRect, _ rhs: CGRect) -> Int {
        Int(
            abs(lhs.origin.x - rhs.origin.x)
                + abs(lhs.origin.y - rhs.origin.y)
                + abs(lhs.width - rhs.width)
                + abs(lhs.height - rhs.height)
        )
    }

    static func signature(for bounds: CGRect?) -> String {
        guard let bounds else { return "no-frame" }
        return "\(Int(bounds.origin.x.rounded())):\(Int(bounds.origin.y.rounded())):\(Int(bounds.width.rounded())):\(Int(bounds.height.rounded()))"
    }
}
