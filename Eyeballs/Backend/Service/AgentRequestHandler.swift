import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation

/// Answers every request on the app's socket, by handing it to the `ReviewService`.
///
/// Expected problems reach the agent as `EyeballsError`s with codes from `ErrorCode`, each
/// with its exit status. Anything else becomes `internal`, which exits 70, and is logged.
struct AgentRequestHandler: RequestHandler {
    let service: ReviewService

    func respond(to request: Request, from peer: Peer) async throws -> HandlerOutcome {
        Log.server.info("\(request.operation.rawValue, privacy: .public) from \(request.client.agent, privacy: .public)")
        do {
            return try await answer(request)
        } catch {
            let failure = Self.agentError(error)
            if failure.code == .internalError {
                Log.server.error("\(request.operation.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            return .failure(failure)
        }
    }

    private func answer(_ request: Request) async throws -> HandlerOutcome {
        let client = request.client
        switch request.operation {
        case .review:
            let (result, text) = try await service.review(try request.decodeArguments(ReviewArguments.self), client: client)
            return try .success(result, text: text)
        case .wait:
            return try await service.wait(try request.decodeArguments(WaitArguments.self), client: client)
        case .inbox:
            let (result, text) = try await service.inbox(try request.decodeArguments(InboxArguments.self), client: client)
            return try .success(result, text: text)
        case .show:
            let (result, text) = try await service.show(try request.decodeArguments(ShowArguments.self), client: client)
            return try .success(result, text: text)
        case .reply:
            let (result, text) = try await service.reply(try request.decodeArguments(ReplyArguments.self), client: client)
            return try .success(result, text: text)
        case .threads:
            let (result, text) = try await service.threads(try request.decodeArguments(ThreadsArguments.self), client: client)
            return try .success(result, text: text)
        case .status:
            let arguments = (try? request.decodeArguments(StatusArguments.self)) ?? StatusArguments(brief: true)
            let (result, text) = await service.status(arguments, client: client)
            return try .success(result, text: text)
        case .attach:
            let (result, text) = try await service.attach(try request.decodeArguments(AttachArguments.self), client: client)
            return try .success(result, text: text)
        case .watch:
            return try await service.watch(client: client)
        case .hook:
            guard let arguments = try? request.decodeArguments(HookArguments.self) else { return try .success(HookResult(output: nil), text: "") }
            return try .success(await service.hook(arguments, client: client), text: "")
        case .open:
            let (result, text) = try await service.open(try request.decodeArguments(OpenArguments.self), client: client)
            return try .success(result, text: text)
        case .doctor:
            let health = await service.health()
            return try .success(health, text: "")
        #if DEBUG
        case .debugSubmitReview:
            let (result, text) = try await service.debugSubmitReview(try request.decodeArguments(DebugSubmitReviewArguments.self), client: client)
            return try .success(result, text: text)
        case .debugSnapshotWindow:
            let arguments = try request.decodeArguments(DebugSnapshotWindowArguments.self)
            guard await service.snapshotWindow(to: arguments.path) else {
                return .failure(EyeballsError(.internalError, "The main window could not be drawn. It may be closed."))
            }
            return try .success(DebugSnapshotWindowResult(path: arguments.path), text: "Saved a picture of the window to \(arguments.path).")
        #endif
        default:
            return .failure(EyeballsError(
                .versionMismatch, "This copy of Eyeballs does not know the operation the eyeballs command asked for.",
                hint: "Update Eyeballs.app or the eyeballs plugin so both are the same version."))
        }
    }

    /// The error the agent sees, with its code from `ErrorCode`.
    static func agentError(_ error: any Error) -> EyeballsError {
        switch error {
        case let error as EyeballsError:
            return error
        case let error as StackError:
            return EyeballsError(
                ErrorCode(rawValue: error.code), error.description,
                hint: error.code == ErrorCode.midOperation.rawValue ? "Finish the operation, then run eyeballs review again." : nil,
                retryAfterSeconds: error.code == ErrorCode.midOperation.rawValue ? 10 : nil)
        case GitError.notARepository:
            return EyeballsError(.notARepo, "This folder is not inside a git repository.", hint: "Run the command from your repository, or pass --stack.")
        case let error as GitError:
            return EyeballsError(.internalError, "Git failed: \(error.description)", hint: "Tell the reviewer, quoting this line.")
        case let error as StoreError:
            return EyeballsError(.internalError, "The Eyeballs store failed: \(error.localizedDescription)", hint: "Tell the reviewer, quoting this line.")
        default:
            return EyeballsError(.internalError, "Eyeballs hit an unexpected error: \(String(describing: error).prefix(300))",
                                 hint: "Tell the reviewer, quoting this line.")
        }
    }
}

#if DEBUG
private struct DebugSnapshotWindowResult: Codable {
    var schema = "eyeballs.debug-snapshot-window/1"
    var ok = true
    var path: String
}
#endif
