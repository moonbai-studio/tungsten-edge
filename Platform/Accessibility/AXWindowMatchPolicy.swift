import CoreGraphics
import Foundation

struct AXWindowMatchPolicy {
    static func matchScore(
        targetTitle: String?,
        targetBounds: CGRect?,
        candidateTitle: String?,
        candidateBounds: CGRect?
    ) -> Int? {
        var score = 0

        if let targetTitle {
            guard let candidateTitle else {
                return nil
            }

            let targetNormalized = normalizedTitle(targetTitle)
            let candidateNormalized = normalizedTitle(candidateTitle)

            if targetNormalized == candidateNormalized {
                score += 0
            } else if candidateNormalized.contains(targetNormalized) || targetNormalized.contains(candidateNormalized) {
                score += 25
            } else {
                return nil
            }
        }

        if let targetBounds {
            guard let candidateBounds else { return nil }
            guard WindowFrameMatchPolicy.areClose(targetBounds, candidateBounds) else {
                return nil
            }
            return score + WindowFrameMatchPolicy.score(targetBounds, candidateBounds)
        }

        return score
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
