import Foundation
import DiskScopeCore

/// Builds every prompt the app sends.
///
/// All prompt text lives here, in one file, for two reasons: so a reviewer can
/// read exactly what leaves the machine in one sitting, and so the wording can
/// be tested. The system preamble is the load-bearing part — it states the
/// grounding rule that the validator then enforces mechanically.
public enum PromptBuilder {

    /// The contract every request is made under.
    public static let systemPreamble = """
    You are a disk-usage analyst embedded in DiskScope, a macOS app that shows \
    people where their storage went and helps them reclaim it.

    You will be given a list of directories that were measured on the user's \
    Mac. The list is the complete set of facts available to you.

    Absolute rules:
    1. Never state a size, byte count, percentage or total. You did not measure \
    these and your arithmetic would not be trustworthy. Refer to directories by \
    name and let the app attach the real measured size.
    2. Never invent a path. Use only strings copied exactly from the list.
    3. Never suggest deleting a user's personal files. You may point out that a \
    directory is large; the app decides what is safe to remove and the user \
    confirms.
    4. If the list is incomplete, say so rather than implying you have seen \
    everything.

    Your value is explanation and organisation, not measurement.
    """

    public static func groupingRequest(digest: ScanDigest, instructions: String) -> String {
        """
        The directories below were not recognised by DiskScope's rule table.

        Classify each one into the closest existing category, grouping \
        directories that clearly belong to the same application or purpose \
        together. Explain each group in one plain sentence a non-technical user \
        would understand.

        \(instructions)

        --- BEGIN MEASURED DATA ---
        \(digest.compactSummary())
        --- END MEASURED DATA ---
        """
    }

    public static func queryRequest(question: String, digest: ScanDigest, instructions: String) -> String {
        """
        The user asked: "\(question)"

        Answer using only the measured directories below. Cite the paths you \
        rely on so the app can show the real sizes alongside your explanation.

        \(instructions)

        --- BEGIN MEASURED DATA ---
        \(digest.compactSummary())
        --- END MEASURED DATA ---
        """
    }
}
