#if DEBUG
import Foundation

extension DemoState {
    /// One repository, "shop", with the stack "checkout-v2": models, api-client and web-ui, and
    /// threads in every state.
    static func seeded(now: Date) -> DemoState {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let source = DemoSources.self
        let you = Author.you(name: reviewer)
        let claude = Author.agent(name: "Claude")

        let models = DemoLayer(
            item: LayerItem(id: 11, position: 1, branch: "models", prNumber: 811, fileCount: 0, additions: 0, deletions: 0, openThreadCount: 0, status: .ready),
            commits: [
                CommitItem(sha: "a1f4c2e9d03b7a51", subject: "Store money as Decimal", author: "Claude", date: ago(5)),
                CommitItem(sha: "7b9d013c55e1f0a2", subject: "Rename CartItem to LineItem", author: "Claude", date: ago(6)),
                CommitItem(sha: "c3e88f5a19d2b647", subject: "Add a Money value type", author: "Claude", date: ago(6.5)),
            ],
            files: [
                DemoDiff.file(path: "Sources/Models/Order.swift", old: source.orderOld, new: source.orderNew),
                DemoDiff.file(path: "Sources/Models/Money.swift", old: nil, new: source.money),
                DemoDiff.file(path: "Sources/Models/LineItem.swift", oldPath: "Sources/Models/CartItem.swift", old: source.cartItem, new: source.lineItem),
                DemoDiff.file(path: "Tests/ModelsTests/OrderTests.swift", old: nil, new: source.orderTests),
                DemoDiff.file(path: "Resources/Fixtures/order.json", old: nil, new: source.orderFixture),
            ])

        let apiClient = DemoLayer(
            item: LayerItem(id: 12, position: 2, branch: "api-client", prNumber: 812, fileCount: 0, additions: 0, deletions: 0, openThreadCount: 0, status: .ready),
            commits: [
                CommitItem(sha: "9f2c1ab47e03d8c6", subject: "Retry only on 5xx and timeouts", author: "Claude", date: ago(1.5)),
                CommitItem(sha: "1d3e4f5b60a7c289", subject: "Add a Retry policy", author: "Claude", date: ago(3)),
                CommitItem(sha: "e57a0b2c91f4d630", subject: "Decode money as Decimal", author: "Claude", date: ago(3.2)),
                CommitItem(sha: "4c8d9e1f2a3b5c70", subject: "Regenerate the API schema", author: "Claude", date: ago(4)),
            ],
            files: [
                DemoDiff.file(path: "Sources/API/Client.swift", old: source.clientOld, new: source.clientNew),
                DemoDiff.file(path: "Sources/API/Retry.swift", old: nil, new: source.retry),
                DemoDiff.file(path: "Sources/API/Endpoints.swift", old: source.endpointsOld, new: source.endpointsNew),
                DemoDiff.file(path: "Sources/API/Generated/Schema.swift", old: nil, new: source.generatedSchema),
                DemoDiff.file(path: ".github/workflows/api-tests.yml", old: nil, new: source.apiWorkflow),
            ])

        let webUI = DemoLayer(
            item: LayerItem(id: 13, position: 3, branch: "web-ui", prNumber: 814, fileCount: 0, additions: 0, deletions: 0, openThreadCount: 0, status: .needsRestack),
            commits: [
                CommitItem(sha: "b2a9c8d7e6f50413", subject: "Show a spinner while the order submits", author: "Claude", date: ago(0.8)),
                CommitItem(sha: "0e1f2a3b4c5d6e7f", subject: "Rename useBasket to useCart", author: "Claude", date: ago(2.4)),
                CommitItem(sha: "5f6e7d8c9b0a1f2e", subject: "Add the checkout hero image", author: "Claude", date: ago(2.6)),
                CommitItem(sha: "8a7b6c5d4e3f2a1b", subject: "Add a seed script for local orders", author: "Claude", date: ago(2.7)),
            ],
            files: [
                DemoDiff.file(path: "Web/Checkout.tsx", old: source.checkoutOld, new: source.checkoutNew),
                DemoDiff.file(path: "Web/components/Spinner.tsx", old: nil, new: source.spinner),
                DemoDiff.file(path: "Web/hooks/useCart.ts", oldPath: "Web/hooks/useBasket.ts", old: source.useBasket, new: source.useCart),
                DemoDiff.binary(path: "Web/assets/checkout-hero.png", change: .added, new: DemoDiff.heroImage()),
                DemoDiff.binary(path: "Web/assets/logo.png", change: .modified,
                                old: DemoDiff.logoImage(fill: .systemBlue), new: DemoDiff.logoImage(fill: .systemOrange)),
                DemoDiff.file(path: "scripts/seed_orders.py", old: nil, new: source.seedOrders),
                DemoDiff.file(path: "scripts/dev.sh", old: source.devScriptOld, new: source.devScriptNew),
            ])

        let layers = [models, apiClient, webUI].map { layer -> DemoLayer in
            var layer = layer
            layer.item.fileCount = layer.files.count
            layer.item.additions = layer.files.reduce(0) { $0 + $1.additions }
            layer.item.deletions = layer.files.reduce(0) { $0 + $1.deletions }
            return layer
        }

        func lines(_ path: String, _ text: String, _ first: String, through last: String? = nil, side: Side = .head) -> ThreadAnchor {
            let start = DemoDiff.line(containing: first, in: text)
            let end = last.map { DemoDiff.line(containing: $0, in: text, after: first) } ?? start
            return .lines(LineRange(path: path, side: side, start: start, end: end))
        }

        var nextComment = 200
        func comment(_ author: Author, _ body: String, _ date: Date, status: ReplyStatus? = nil, pending: Bool = false, edited: Bool = false) -> CommentItem {
            defer { nextComment += 1 }
            return CommentItem(id: nextComment, author: author, replyStatus: status, body: body, date: date, isPending: pending, isEdited: edited)
        }

        let threads = [
            DemoThread(id: 38, layerID: 12, anchor: .layer, comments: [
                comment(you, "Can this layer land before web-ui? I'd like to ship the client changes on their own.", ago(20)),
                comment(claude, "It can, as long as nothing calls `Client.placeOrder` yet. Do you want me to put it behind the `checkoutV2` flag as well?", ago(3), status: .question),
            ]),
            DemoThread(id: 39, layerID: 12, anchor: .file(path: "Sources/API/Endpoints.swift"), comments: [
                comment(you, "These two paths disagree on the plural. Pick one.", ago(22)),
                comment(claude, "Both use `/v1/orders` now, built from one `version` constant. The singular route is gone.", ago(3), status: .addressed),
            ], anchorNote: "Outdated: the lines this thread was on are gone. They were near line 8 in r3.",
               originalLines: ["    static func order(_ id: String) -> String {", "        \"/v1/order/\\(id)\"", "    }"]),
            DemoThread(id: 40, layerID: 11, anchor: lines("Sources/Models/Money.swift", source.money, "static func < "), comments: [
                comment(you, "Should `Money` be `Comparable`? The basket sorts by price.", ago(26)),
                comment(claude, "Added `Comparable`. It refuses to compare two currencies, the same as `+` does.", ago(6), status: .addressed),
            ], isResolved: true),
            DemoThread(id: 41, layerID: 11, anchor: lines("Sources/Models/Order.swift", source.orderNew, "var items: [LineItem]", through: "var total: Money"), comments: [
                comment(you, "Use `Decimal` for money, not `Double`. Floating point will lose pennies on refunds.", ago(26)),
                comment(claude, "Money is a `Decimal` now, wrapped in a `Money` type that carries its currency. Both callers are updated, and `OrderTests.pennyAmountsNeverDrift` covers it.", ago(5), status: .addressed),
            ]),
            DemoThread(id: 42, layerID: 12, anchor: lines("Sources/API/Client.swift", source.clientNew, "var attempt = 0", through: "try await Task.sleep(for: retry.delay"), comments: [
                comment(you, "This retries on 4xx too. Only retry 5xx and timeouts.", ago(22)),
                comment(claude, """
                Only 5xx and `URLError.timedOut` retry now. A 4xx fails at once:

                ```swift
                case .status(let code, _): (500..<600).contains(code)
                ```

                See `Retry.shouldRetry(_:attempt:)`.
                """, ago(1.5), status: .addressed),
            ]),
            DemoThread(id: 43, layerID: 12, anchor: .file(path: "Sources/API/Client.swift"), comments: [
                comment(you, "Give the retry logic its own type so tests can drive it.", ago(22)),
                comment(claude, "It has its own type in `Retry.swift`, but I kept it internal. Tests use `@testable import`, and making it public would widen the API for one test.", ago(1.5), status: .declined),
            ]),
            DemoThread(id: 44, layerID: 13, anchor: lines("Web/Checkout.tsx", source.checkoutNew, "{isSubmitting ? <Spinner"), comments: [
                comment(you, "Show a spinner while the order submits. People double-click **Place order** today.", ago(19), edited: true),
                comment(claude, "Should the spinner block the whole form, or just the **Place order** button? Right now the address form is disabled too.", ago(0.8), status: .question),
            ]),
            DemoThread(id: 45, layerID: 13, anchor: lines("Web/Checkout.tsx", source.checkoutNew, "const total = sumMoney"), comments: [
                comment(you, "This total is recomputed on every keystroke in the note field. Memoize it with `useMemo`.", ago(0.5)),
            ], anchorNote: "Moved from line 98 (r3)"),
            DemoThread(id: 46, layerID: 12, anchor: lines("Sources/API/Client.swift", source.clientNew, "request.timeoutInterval = 30"), comments: [
                comment(you, "Is 30 seconds right for checkout? It feels long for a payment call.", ago(0.2), pending: true),
            ]),
            DemoThread(id: 47, layerID: 11, anchor: lines("Sources/Models/LineItem.swift", source.lineItem, "var quantity: Int"), comments: [
                comment(you, "Nit: `quantity` can't be negative. Validate it in `init`, or say why it can't happen.", ago(0.3), pending: true),
            ]),
        ]

        let stack = StackItem(id: 3, name: "checkout-v2", trunk: "main", revision: 4, layers: layers.map(\.item), openThreadCount: 0, needsYouCount: 0)
        let repository = RepositoryItem(id: 1, name: "shop", path: "/Users/alex/src/shop", stacks: [stack])
        return DemoState(repository: repository, stack: stack, layers: layers, threads: threads)
    }
}
#endif
