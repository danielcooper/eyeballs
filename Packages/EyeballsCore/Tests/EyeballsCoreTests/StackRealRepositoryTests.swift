import EyeballsCore
import Foundation
import Testing

/// Reads every stack in a real gh-stack repository and checks each layer against plain git.
///
/// It only reads, so it is safe on a working clone. Set `EYEBALLS_READONLY_STACK_REPO` to the
/// repository's path to run it, for example:
/// `EYEBALLS_READONLY_STACK_REPO=~/src/shop swift test --filter StackRealRepositoryTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EYEBALLS_READONLY_STACK_REPO"] != nil))
struct StackRealRepositoryTests {
    @Test func everyLayerMatchesPlainGit() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["EYEBALLS_READONLY_STACK_REPO"])
        let repository = try await GitRepository.locate(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let catalog = try #require(try GhStackCatalog.load(commonDirectory: repository.commonDirectory))
        let reader = StackReader(repository: repository)

        for entry in catalog.stacks {
            guard let first = entry.branches.first?.branch else { continue }
            let stack = try await reader.ghStack(containing: first, refuseDuringOperation: false)
            print("Stack \(stack.name) on \(stack.trunk): \(stack.layers.count) layers, warnings: \(stack.warnings)")
            for layer in stack.layers {
                let commits = try await repository.commits(from: layer.base, to: layer.head)
                let files = try await repository.changedFiles(from: layer.base, to: layer.head)
                let numstat = try await repository.numstat(from: layer.base, to: layer.head)
                print("  \(layer.position) \(layer.branch) PR \(layer.pullRequest?.number ?? 0): \(layer.baseRule.rawValue) against \(layer.parentRef), base \(layer.base.short), head \(layer.head.short), \(commits.count) commits, \(files.count) files\(layer.needsRestack ? ", needs restack" : "")")

                #expect(try await repository.isAncestor(layer.base.hex, of: layer.head.hex))
                #expect(try await repository.resolveCommit("refs/heads/\(layer.branch)") == layer.head)
                if layer.baseRule == .parentTip {
                    #expect(try await repository.resolveCommit(layer.parentRef) == layer.base)
                }
                if layer.baseRule == .mergeBase {
                    #expect(try await repository.mergeBase(layer.parentRef, layer.head.hex) == layer.base)
                }
                #expect(files.count == numstat.count)
                for (file, counts) in zip(files, numstat) where !file.isBinary {
                    #expect(counts.additions == file.additions && counts.deletions == file.deletions, "\(file.path)")
                }
            }
        }
    }
}
