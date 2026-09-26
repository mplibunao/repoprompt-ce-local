import Foundation

/// A user instruction queued for delivery at the next turn boundary. It carries the submissions
/// it stands for, so the turn that delivers it consumes their queued input-token estimate and no
/// other, and so it can give them back to the composer if it never runs.
struct AgentQueuedInstruction: Equatable {
    /// The provider text the delivering turn sends, after workflow wrapping.
    let text: String
    /// The submission whose queued input-token estimate the delivering turn consumes; an entry
    /// standing for several submissions holds all of their estimates under this one. `nil` for an
    /// instruction that has no queued estimate.
    let submissionID: UUID?
    /// Every optimistic user item this entry stands for, in submission order.
    let constituentSubmissionIDs: [UUID]
    /// What the user typed for this entry, before workflow wrapping or slash-skill expansion; an
    /// entry standing for several submissions joins their drafts with newlines.
    let restorationDraftText: String
}
