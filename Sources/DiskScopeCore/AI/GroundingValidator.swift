import Foundation

/// Checks model output against measured data before the UI is allowed to show it.
///
/// A language model asked about a filesystem will occasionally produce a path
/// that does not exist, or a plausible-sounding claim about a directory it was
/// never shown. Rather than trying to catch those in prose, every path a model
/// cites is resolved against the `ScanDigest` and dropped if it is not there.
///
/// This is deliberately strict. A response that cites one unverifiable path
/// loses that citation but keeps its text; the UI then shows the answer with a
/// visible note that some references were discarded, rather than silently
/// presenting a half-verified claim as fully grounded.
public enum GroundingValidator {

    /// Verify grouping proposals, discarding any that reference unknown paths.
    public static func validate(
        proposals: [GroupingProposal],
        against digest: ScanDigest
    ) -> (accepted: [GroupingProposal], rejected: [RejectedProposal]) {
        var accepted: [GroupingProposal] = []
        var rejected: [RejectedProposal] = []

        for proposal in proposals {
            // An empty group is meaningless.
            guard !proposal.paths.isEmpty else {
                rejected.append(RejectedProposal(
                    paths: proposal.paths,
                    reason: "no paths"
                ))
                continue
            }

            let unknown = proposal.paths.filter { !digest.contains(path: $0) }
            if !unknown.isEmpty {
                rejected.append(RejectedProposal(
                    paths: unknown,
                    reason: "not found in the scan"
                ))
                continue
            }

            accepted.append(proposal)
        }

        // Overlapping groups would double-count if summed. Keep the largest and
        // drop the overlaps, recording it so the UI can be honest about it.
        let (deduplicated, overlaps) = removeOverlaps(accepted)
        rejected.append(contentsOf: overlaps)

        return (deduplicated, rejected)
    }

    /// Resolve a raw model answer against the digest.
    public static func validate(
        answer: QueryAnswer,
        against digest: ScanDigest
    ) -> QueryAnswer {
        let verified = answer.citedPaths.filter { digest.contains(path: $0) }
        let unverified = answer.citedPaths.filter { !digest.contains(path: $0) }

        return QueryAnswer(
            summary: answer.summary,
            citedPaths: verified,
            rejectedPaths: unverified
        )
    }

    /// Drop a proposal whose paths are already claimed by a larger one.
    ///
    /// Greedy by descending size, which keeps the most substantial grouping and
    /// discards the thinner duplicate. Without this, summing group sizes would
    /// overstate reclaimable space — the same class of dishonesty we are trying
    /// to avoid elsewhere in the app.
    private static func removeOverlaps(
        _ proposals: [GroupingProposal]
    ) -> (kept: [GroupingProposal], dropped: [RejectedProposal]) {
        let ordered = proposals.sorted {
            $0.paths.count > $1.paths.count
        }

        var claimed = Set<String>()
        var kept: [GroupingProposal] = []
        var dropped: [RejectedProposal] = []

        for proposal in ordered {
            let alreadyClaimed = proposal.paths.filter { claimed.contains($0) }
            if alreadyClaimed.isEmpty {
                kept.append(proposal)
                claimed.formUnion(proposal.paths)
            } else {
                let remainder = proposal.paths.filter { !claimed.contains($0) }
                dropped.append(RejectedProposal(
                    paths: alreadyClaimed,
                    reason: "already claimed by a larger group"
                ))
                if !remainder.isEmpty {
                    // Keep the unclaimed remainder rather than losing it.
                    kept.append(GroupingProposal(
                        paths: remainder,
                        suggestedCategory: proposal.suggestedCategory,
                        rationale: proposal.rationale
                    ))
                    claimed.formUnion(remainder)
                }
            }
        }

        return (kept, dropped)
    }
}

/// A proposal or citation that failed verification.
public struct RejectedProposal: Sendable {
    public let paths: [String]
    public let reason: String

    public init(paths: [String], reason: String) {
        self.paths = paths
        self.reason = reason
    }
}
