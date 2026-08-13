import Foundation

/// One element of an ``Extract/stream(from:as:using:options:)`` sequence.
///
/// The stream always ends with ``final(_:)`` on success (so callers never need a
/// second call for the complete result). Errors propagate by throwing from the
/// stream instead of yielding a failure case.
///
/// ## Completed-token rule
///
/// ``partial(_:)`` values are built only from JSON tokens that are **provably
/// complete**. A number is not surfaced until a delimiter follows it; a string
/// waits for its closing quote. That is a deliberate trade of latency for
/// truthfulness: showing `47` while the model is still writing `473.00` would
/// put a wrong total on screen, which is worse than an empty field. Do not
/// "optimise" this by streaming half-tokens.
///
/// Growing collections are fine — `lineItems` may go from 1 element to 3 as
/// each element completes.
///
/// ## What partials do **not** carry
///
/// Partials are a UI preview, not an evidenced result. Signals, provenance,
/// grounding, and tables are computed for ``final(_:)`` only.
public enum ExtractionUpdate<T: Extractable>: Sendable {
    /// A progressive snapshot. Every field of ``Extractable/Partial`` is optional;
    /// absent means "not yet complete", not "null in the document".
    case partial(T.Partial)
    /// Terminal success value — identical shape to ``Extract/detailed(from:as:using:options:)``.
    ///
    /// Under ``InvariantPolicy/reportViolations``, this is still yielded when
    /// invariants failed after retries (``ExtractionResult/invariantViolations``
    /// is non-empty). Under the default ``InvariantPolicy/strict``, the stream
    /// throws instead — same as ``Extract/detailed``.
    case final(ExtractionResult<T>)
}
