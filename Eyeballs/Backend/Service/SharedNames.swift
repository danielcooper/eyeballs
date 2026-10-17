import EyeballsCore
import EyeballsKit
import EyeballsStore

// The git core, the wire protocol, the store and the window each have their own type for some of
// the same ideas, such as a diff side. These names say which one a line of the backend means.

typealias GitSide = EyeballsCore.DiffSide
typealias GitStackSource = EyeballsCore.StackSource

typealias StoredAnchorState = EyeballsStore.AnchorState
typealias StoredBaseRule = EyeballsStore.BaseRule
typealias StoredReviewStatus = EyeballsStore.ReviewStatus
typealias StoredSide = EyeballsStore.DiffSide
typealias StoredSource = EyeballsStore.StackSource
typealias StoredSubject = EyeballsStore.ThreadSubject
typealias StoredThreadStatus = EyeballsStore.ThreadStatus

typealias WireAnchorState = EyeballsKit.AnchorState
typealias WireReplyStatus = EyeballsKit.ReplyStatus
typealias WireSide = EyeballsKit.DiffSide
typealias WireSource = EyeballsKit.StackSource
typealias WireSubject = EyeballsKit.ThreadSubject
typealias WireThreadFilter = EyeballsKit.ThreadFilter
typealias WireThreadStatus = EyeballsKit.ThreadStatus
typealias WireVerdict = EyeballsKit.Verdict

extension StoredSide {
    var git: GitSide { self == .base ? .base : .head }
    var wire: WireSide { WireSide(rawValue: rawValue) }
}

extension StoredSubject {
    var wire: WireSubject { WireSubject(rawValue: rawValue) }
}

extension StoredAnchorState {
    var wire: WireAnchorState { WireAnchorState(rawValue: rawValue) }

    /// A state a later port may start from. `outdated` and `gone` anchors never are.
    var isGood: Bool {
        switch self {
        case .original, .current, .moved, .whitespace, .changed, .relocated: true
        default: false
        }
    }
}

extension StoredThreadStatus {
    var wire: WireThreadStatus { WireThreadStatus(rawValue: rawValue) }
}

extension StoredSource {
    init(_ source: GitStackSource) {
        self.init(rawValue: source.rawValue)
    }

    var wire: WireSource { WireSource(rawValue: rawValue) }
}

extension ReviewVerdict {
    var wire: WireVerdict { WireVerdict(rawValue: rawValue) }

    init(_ verdict: WireVerdict) {
        self.init(rawValue: verdict.rawValue)
    }
}

extension AgentReplyStatus {
    var wire: WireReplyStatus? { WireReplyStatus(rawValue: rawValue) }

    init(_ status: WireReplyStatus) {
        self.init(rawValue: status.rawValue)
    }
}

extension AgentThreadKind {
    var wire: ThreadKind { ThreadKind(rawValue: rawValue) }
}
