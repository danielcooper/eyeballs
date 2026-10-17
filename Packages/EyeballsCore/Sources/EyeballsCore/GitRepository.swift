import Foundation

/// One repository, found from any folder inside it, with a git runner and a blob reader for it.
public struct GitRepository: Sendable {
    /// The checked-out folder, or nil for a bare repository.
    public let workTree: URL?
    /// This worktree's own git folder: `.git` for the main worktree, `.git/worktrees/<id>` for a linked one.
    public let gitDirectory: URL
    /// The folder every worktree shares, where refs, objects and the gh-stack catalog live.
    public let commonDirectory: URL
    public let git: Git
    /// Reads blobs through one long-lived `git cat-file --batch`.
    public let blobs: BlobReader

    public var isLinkedWorktree: Bool { gitDirectory.path != commonDirectory.path }

    /// Finds the repository that holds `folder`.
    ///
    /// `folder` can be anywhere in a work tree, inside a `.git` folder, inside a linked worktree's
    /// `.git/worktrees/<id>` folder, or inside a bare repository. Throws `GitError.notARepository`
    /// when it is none of these.
    public static func locate(from folder: URL, executable: URL = Git.defaultExecutable) async throws -> GitRepository {
        let probe = Git(directory: folder, executable: executable)
        let answer = try await probe.run(
            ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--is-bare-repository", "--is-inside-work-tree"],
            acceptedStatuses: [0, 128]
        )
        guard answer.status == 0 else { throw GitError.notARepository }
        let lines = answer.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 4 else {
            throw GitError.unexpectedOutput(subcommand: "rev-parse", expected: "4 lines: git dir, common dir, bare flag, work tree flag")
        }
        let gitDirectory = URL(fileURLWithPath: lines[0], isDirectory: true)
        let commonDirectory = URL(fileURLWithPath: lines[1], isDirectory: true)
        let isBare = lines[2] == "true"
        let isInsideWorkTree = lines[3] == "true"

        var workTree: URL?
        if isInsideWorkTree {
            let top = try await probe.run(["rev-parse", "--path-format=absolute", "--show-toplevel"])
            workTree = URL(fileURLWithPath: top.text, isDirectory: true)
        } else if !isBare {
            workTree = workTreeOwning(gitDirectory: gitDirectory, commonDirectory: commonDirectory)
        }
        return GitRepository(workTree: workTree, gitDirectory: gitDirectory, commonDirectory: commonDirectory, executable: executable)
    }

    public init(workTree: URL?, gitDirectory: URL, commonDirectory: URL, executable: URL = Git.defaultExecutable) {
        self.workTree = workTree
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
        self.git = Git(directory: workTree ?? gitDirectory, executable: executable)
        self.blobs = BlobReader(git: git)
    }

    /// Works out the work tree when you start inside a git folder rather than the files it tracks.
    static func workTreeOwning(gitDirectory: URL, commonDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        if gitDirectory.path == commonDirectory.path {
            guard gitDirectory.lastPathComponent == ".git" else { return nil }
            return gitDirectory.deletingLastPathComponent()
        }
        // A linked worktree's admin folder holds `gitdir`, the path of the `.git` file in its work tree.
        guard let pointer = try? String(contentsOf: gitDirectory.appendingPathComponent("gitdir"), encoding: .utf8) else { return nil }
        let path = pointer.trimmingCharacters(in: .newlines)
        let dotGit = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: gitDirectory).absoluteURL.standardized
        let workTree = dotGit.deletingLastPathComponent()
        return fileManager.fileExists(atPath: workTree.path) ? workTree : nil
    }
}
