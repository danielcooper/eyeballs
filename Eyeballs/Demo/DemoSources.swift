#if DEBUG
import Foundation

/// The old and new text of every file in the demo stack "checkout-v2".
enum DemoSources {
    // MARK: Layer 1: models

    static let orderOld = #"""
import Foundation

/// An order as the checkout flow builds it, before it is sent to the server.
struct Order: Codable, Identifiable, Equatable {
    var id: String
    var customerID: String
    var items: [CartItem]
    var total: Double
    var currency: String
    var status: Status
    var createdAt: Date
    var note: String?

    enum Status: String, Codable {
        case draft
        case placed
        case paid
        case shipped
        case cancelled
    }

    init(id: String = UUID().uuidString, customerID: String, items: [CartItem] = [], currency: String = "GBP") {
        self.id = id
        self.customerID = customerID
        self.items = items
        self.total = items.reduce(0) { $0 + $1.price * Double($1.quantity) }
        self.currency = currency
        self.status = .draft
        self.createdAt = Date()
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    var itemCount: Int {
        items.reduce(0) { $0 + $1.quantity }
    }

    mutating func add(_ item: CartItem) {
        if let index = items.firstIndex(where: { $0.sku == item.sku }) {
            items[index].quantity += item.quantity
        } else {
            items.append(item)
        }
        recalculate()
    }

    mutating func remove(sku: String) {
        items.removeAll { $0.sku == sku }
        recalculate()
    }

    mutating func setQuantity(_ quantity: Int, for sku: String) {
        guard let index = items.firstIndex(where: { $0.sku == sku }) else { return }
        if quantity <= 0 {
            items.remove(at: index)
        } else {
            items[index].quantity = quantity
        }
        recalculate()
    }

    private mutating func recalculate() {
        total = items.reduce(0) { $0 + $1.price * Double($1.quantity) }
    }

    // MARK: Status

    var canBeCancelled: Bool {
        status == .draft || status == .placed
    }

    mutating func place() throws {
        guard !items.isEmpty else { throw OrderError.empty }
        guard status == .draft else { throw OrderError.alreadyPlaced }
        status = .placed
    }

    mutating func cancel() throws {
        guard canBeCancelled else { throw OrderError.cannotCancel(status) }
        status = .cancelled
    }
}

enum OrderError: Error, Equatable {
    case empty
    case alreadyPlaced
    case cannotCancel(Order.Status)
}

extension Order {
    /// The total as the receipt shows it, for example "£12.50".
    var formattedTotal: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: total)) ?? "\(total)"
    }
}
"""#

    static let orderNew = #"""
import Foundation

/// An order as the checkout flow builds it, before it is sent to the server.
struct Order: Codable, Identifiable, Equatable {
    var id: String
    var customerID: String
    var items: [LineItem]
    var total: Money
    var status: Status
    var createdAt: Date
    var note: String?

    enum Status: String, Codable {
        case draft
        case placed
        case paid
        case shipped
        case refunded
        case cancelled
    }

    init(id: String = UUID().uuidString, customerID: String, items: [LineItem] = [], currency: Currency = .gbp) {
        self.id = id
        self.customerID = customerID
        self.items = items
        self.total = Money(amount: 0, currency: currency)
        self.status = .draft
        self.createdAt = Date()
        recalculate()
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    var itemCount: Int {
        items.reduce(0) { $0 + $1.quantity }
    }

    mutating func add(_ item: LineItem) {
        if let index = items.firstIndex(where: { $0.sku == item.sku }) {
            items[index].quantity += item.quantity
        } else {
            items.append(item)
        }
        recalculate()
    }

    mutating func remove(sku: String) {
        items.removeAll { $0.sku == sku }
        recalculate()
    }

    mutating func setQuantity(_ quantity: Int, for sku: String) {
        guard let index = items.firstIndex(where: { $0.sku == sku }) else { return }
        if quantity <= 0 {
            items.remove(at: index)
        } else {
            items[index].quantity = quantity
        }
        recalculate()
    }

    private mutating func recalculate() {
        let amount = items.reduce(Decimal.zero) { $0 + $1.unitPrice.amount * Decimal($1.quantity) }
        total = Money(amount: amount, currency: total.currency)
    }

    // MARK: Status

    var canBeCancelled: Bool {
        status == .draft || status == .placed
    }

    var canBeRefunded: Bool {
        status == .paid || status == .shipped
    }

    mutating func place() throws {
        guard !items.isEmpty else { throw OrderError.empty }
        guard status == .draft else { throw OrderError.alreadyPlaced }
        status = .placed
    }

    mutating func cancel() throws {
        guard canBeCancelled else { throw OrderError.cannotCancel(status) }
        status = .cancelled
    }

    mutating func refund() throws {
        guard canBeRefunded else { throw OrderError.cannotRefund(status) }
        status = .refunded
    }
}

enum OrderError: Error, Equatable {
    case empty
    case alreadyPlaced
    case cannotCancel(Order.Status)
    case cannotRefund(Order.Status)
}

extension Order {
    /// The total as the receipt shows it, for example "£12.50".
    var formattedTotal: String {
        total.formatted()
    }
}
"""#

    static let money = #"""
import Foundation

/// An amount of money in one currency. Amounts are `Decimal`, so pennies never drift.
struct Money: Codable, Hashable, Comparable, Sendable {
    var amount: Decimal
    var currency: Currency

    static func zero(_ currency: Currency) -> Money {
        Money(amount: 0, currency: currency)
    }

    static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Add money in one currency only")
        return Money(amount: lhs.amount + rhs.amount, currency: lhs.currency)
    }

    static func * (lhs: Money, rhs: Int) -> Money {
        Money(amount: lhs.amount * Decimal(rhs), currency: lhs.currency)
    }

    static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(lhs.currency == rhs.currency, "Compare money in one currency only")
        return lhs.amount < rhs.amount
    }

    /// For example "£12.50".
    func formatted(locale: Locale = .current) -> String {
        amount.formatted(.currency(code: currency.code).locale(locale))
    }
}

enum Currency: String, Codable, Hashable, Sendable, CaseIterable {
    case gbp = "GBP"
    case eur = "EUR"
    case usd = "USD"

    var code: String { rawValue }

    /// How many digits follow the decimal point in prices.
    var minorUnits: Int { 2 }
}
"""#

    static let cartItem = #"""
import Foundation

/// One product in the basket, with how many the customer wants.
struct CartItem: Codable, Hashable, Identifiable {
    var id: String { sku }
    var sku: String
    var name: String
    var price: Double
    var quantity: Int
    var imageURL: URL?

    var lineTotal: Double {
        price * Double(quantity)
    }
}
"""#

    static let lineItem = #"""
import Foundation

/// One product on an order, with how many the customer wants.
struct LineItem: Codable, Hashable, Identifiable {
    var id: String { sku }
    var sku: String
    var name: String
    var unitPrice: Money
    var quantity: Int
    var imageURL: URL?

    var lineTotal: Money {
        unitPrice * quantity
    }
}
"""#

    static let orderTests = #"""
import Foundation
import Testing
@testable import Models

struct OrderTests {
    private func item(_ sku: String, price: Decimal, quantity: Int = 1) -> LineItem {
        LineItem(sku: sku, name: sku.capitalized, unitPrice: Money(amount: price, currency: .gbp), quantity: quantity)
    }

    @Test func totalAddsEveryLine() {
        var order = Order(customerID: "c_42")
        order.add(item("tea", price: 3.20, quantity: 2))
        order.add(item("scone", price: 2.95))
        #expect(order.total == Money(amount: 9.35, currency: .gbp))
    }

    @Test func addingTheSameSkuRaisesTheQuantity() {
        var order = Order(customerID: "c_42")
        order.add(item("tea", price: 3.20))
        order.add(item("tea", price: 3.20))
        #expect(order.items.count == 1)
        #expect(order.itemCount == 2)
    }

    @Test func pennyAmountsNeverDrift() {
        var order = Order(customerID: "c_42")
        for _ in 0..<10 { order.add(item("sweet-\(UUID())", price: 0.10)) }
        #expect(order.total.amount == 1)
    }

    @Test func settingQuantityToZeroRemovesTheLine() {
        var order = Order(customerID: "c_42", items: [item("tea", price: 3.20)])
        order.setQuantity(0, for: "tea")
        #expect(order.isEmpty)
    }

    @Test func anEmptyOrderCannotBePlaced() {
        var order = Order(customerID: "c_42")
        #expect(throws: OrderError.empty) { try order.place() }
    }

    @Test func onlyPaidOrdersCanBeRefunded() throws {
        var order = Order(customerID: "c_42", items: [item("tea", price: 3.20)])
        try order.place()
        #expect(throws: OrderError.cannotRefund(.placed)) { try order.refund() }
        order.status = .paid
        try order.refund()
        #expect(order.status == .refunded)
    }

    @Test func formattedTotalUsesTheCurrency() {
        let order = Order(customerID: "c_42", items: [item("tea", price: 12.5)])
        #expect(order.formattedTotal.contains("12.50"))
    }
}
"""#

    static let orderFixture = #"""
{
  "id": "ord_01HZX3K9",
  "customerID": "c_42",
  "status": "placed",
  "createdAt": "2026-10-14T09:12:44Z",
  "total": {
    "amount": "9.35",
    "currency": "GBP"
  },
  "items": [
    {
      "sku": "tea",
      "name": "Breakfast tea",
      "unitPrice": { "amount": "3.20", "currency": "GBP" },
      "quantity": 2
    },
    {
      "sku": "scone",
      "name": "Fruit scone",
      "unitPrice": { "amount": "2.95", "currency": "GBP" },
      "quantity": 1
    }
  ],
  "note": null
}
"""#

    // MARK: Layer 2: api-client

    static let clientOld = #"""
import Foundation
import Models

/// Talks to the shop API. Every call is authenticated and decoded here.
final class Client: @unchecked Sendable {
    let baseURL: URL
    private let session: URLSession
    private let tokens: TokenStore
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession = .shared, tokens: TokenStore) {
        self.baseURL = baseURL
        self.session = session
        self.tokens = tokens
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: Orders

    func order(id: String) async throws -> Order {
        try await decode(Order.self, from: get(Endpoints.order(id)))
    }

    func orders(for customerID: String) async throws -> [Order] {
        try await decode([Order].self, from: get(Endpoints.orders(customer: customerID)))
    }

    func placeOrder(_ order: Order) async throws -> Order {
        let body = try JSONEncoder().encode(order)
        return try await decode(Order.self, from: post(Endpoints.orders, body: body))
    }

    // MARK: Requests

    func get(_ path: String) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await send(request(path, method: "GET"))
            } catch {
                attempt += 1
                if attempt >= 3 { throw error }
                try await Task.sleep(for: .seconds(attempt))
            }
        }
    }

    func post(_ path: String, body: Data) async throws -> Data {
        var request = request(path, method: "POST")
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 60
        if let token = tokens.current {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.status(http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ClientError.decoding(String(describing: type), error)
        }
    }
}

enum ClientError: Error {
    case notHTTP
    case status(Int, body: String)
    case decoding(String, Error)
}

protocol TokenStore: Sendable {
    var current: String? { get }
}
"""#

    static let clientNew = #"""
import Foundation
import Models

/// Talks to the shop API. Every call is authenticated and decoded here.
final class Client: @unchecked Sendable {
    let baseURL: URL
    private let session: URLSession
    private let tokens: TokenStore
    private let decoder: JSONDecoder
    private let retry: Retry

    init(baseURL: URL, session: URLSession = .shared, tokens: TokenStore, retry: Retry = .standard) {
        self.baseURL = baseURL
        self.session = session
        self.tokens = tokens
        self.retry = retry
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .throw
        self.decoder = decoder
    }

    // MARK: Orders

    func order(id: String) async throws -> Order {
        try await decode(Order.self, from: get(Endpoints.order(id)))
    }

    func orders(for customerID: String) async throws -> [Order] {
        try await decode([Order].self, from: get(Endpoints.orders(customer: customerID)))
    }

    func placeOrder(_ order: Order) async throws -> Order {
        let body = try JSONEncoder().encode(order)
        return try await decode(Order.self, from: post(Endpoints.orders, body: body))
    }

    // MARK: Requests

    func get(_ path: String) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await send(request(path, method: "GET"))
            } catch where retry.shouldRetry(error, attempt: attempt) {
                attempt += 1
                try await Task.sleep(for: retry.delay(after: attempt))
            }
        }
    }

    func post(_ path: String, body: Data) async throws -> Data {
        var request = request(path, method: "POST")
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        return try await send(request)
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let token = tokens.current {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.status(http.statusCode, body: String(decoding: data.prefix(2_048), as: UTF8.self))
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ClientError.decoding(String(describing: type), error)
        }
    }
}

enum ClientError: Error {
    case notHTTP
    case status(Int, body: String)
    case decoding(String, Error)

    /// True for errors a retry might fix: server errors and timeouts, never 4xx.
    var isTransient: Bool {
        switch self {
        case .status(let code, _): (500..<600).contains(code)
        case .notHTTP, .decoding: false
        }
    }
}

protocol TokenStore: Sendable {
    var current: String? { get }
}
"""#

    static let retry = #"""
import Foundation

/// When the client tries a request again, and how long it waits first.
struct Retry: Sendable {
    var maxAttempts: Int
    var baseDelay: Duration
    var maxDelay: Duration

    static let standard = Retry(maxAttempts: 3, baseDelay: .milliseconds(300), maxDelay: .seconds(5))
    static let never = Retry(maxAttempts: 0, baseDelay: .zero, maxDelay: .zero)

    /// Retries server errors and timeouts only. A 4xx means the request is wrong, so it fails at once.
    func shouldRetry(_ error: Error, attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        switch error {
        case let error as ClientError:
            return error.isTransient
        case let error as URLError:
            return error.code == .timedOut || error.code == .networkConnectionLost
        default:
            return false
        }
    }

    /// Doubles the wait each time, with up to 20% jitter, and never waits longer than `maxDelay`.
    func delay(after attempt: Int) -> Duration {
        let exponential = baseDelay * Int(pow(2.0, Double(max(0, attempt - 1))))
        let jitter = Double.random(in: 0.8...1.2)
        return min(maxDelay, exponential * jitter)
    }
}
"""#

    static let endpointsOld = #"""
import Foundation

/// Every path the client calls, in one place.
enum Endpoints {
    static let orders = "/v1/orders"

    static func order(_ id: String) -> String {
        "/v1/order/\(id)"
    }

    static func orders(customer: String) -> String {
        "/v1/customers/\(customer)/orders"
    }

    static let health = "/health"
}
"""#

    static let endpointsNew = #"""
import Foundation

/// Every path the client calls, in one place.
enum Endpoints {
    static let version = "v1"
    static let orders = "/\(version)/orders"

    static func order(_ id: String) -> String {
        "\(orders)/\(id)"
    }

    static func orders(customer: String) -> String {
        "/\(version)/customers/\(customer)/orders"
    }

    static func refund(_ orderID: String) -> String {
        "\(order(orderID))/refund"
    }

    static let health = "/health"
}
"""#

    static let apiWorkflow = #"""
name: API client tests

on:
  pull_request:
    paths:
      - "Sources/API/**"
      - "Tests/APITests/**"
  workflow_dispatch:

jobs:
  test:
    runs-on: macos-15
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.4.app
      - name: Run API tests
        run: swift test --filter APITests
        env:
          SHOP_API_BASE_URL: https://staging.shop.example
          RETRY_MAX_ATTEMPTS: 3
"""#

    /// A generated file of more than 400 lines, so it starts collapsed behind "Load diff".
    static var generatedSchema: String {
        let models = [
            "Address", "Basket", "BasketLine", "Card", "Carrier", "Category", "Coupon", "Customer", "Delivery",
            "DeliverySlot", "Discount", "GiftCard", "Image", "Inventory", "Invoice", "Locale", "LoyaltyAccount",
            "Merchant", "OrderEvent", "OrderLine", "OrderSummary", "Parcel", "Payment", "PaymentMethod", "PickupPoint",
            "Price", "Product", "ProductVariant", "Promotion", "Receipt", "Refund", "Review", "Shipment", "Store",
            "Subscription", "TaxLine", "TaxRate", "Warehouse", "Webhook", "WishList",
        ]
        let fields = [("id", "String"), ("createdAt", "Date"), ("updatedAt", "Date"), ("name", "String"),
                      ("status", "String"), ("version", "Int"), ("metadata", "[String: String]")]
        var lines = [
            "// Generated by openapi-gen 2.4.1 from shop-api.yaml on 2026-10-15.",
            "// Do not edit this file by hand. Run `make schema` instead.",
            "",
            "import Foundation",
            "",
        ]
        for model in models {
            lines.append("public struct \(model): Codable, Hashable, Sendable {")
            for (name, type) in fields {
                lines.append("    public var \(name): \(type)")
            }
            lines.append("")
            lines.append("    enum CodingKeys: String, CodingKey {")
            lines.append("        case id, createdAt = \"created_at\", updatedAt = \"updated_at\", name, status, version, metadata")
            lines.append("    }")
            lines.append("}")
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Layer 3: web-ui

    static let checkoutOld = #"""
import React, { useState } from "react";
import { useBasket } from "./hooks/useBasket";
import { placeOrder } from "./api/orders";
import { formatMoney } from "./format";
import { AddressForm } from "./components/AddressForm";
import { LineItemRow } from "./components/LineItemRow";
import styles from "./Checkout.module.css";

type Props = {
  customerId: string;
  onPlaced: (orderId: string) => void;
};

export function Checkout({ customerId, onPlaced }: Props) {
  const { items, setQuantity, clear } = useBasket(customerId);
  const [address, setAddress] = useState<Address | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState("");

  const total = items.reduce((sum, item) => sum + item.price * item.quantity, 0);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!address) {
      setError("Add a delivery address first.");
      return;
    }
    try {
      const order = await placeOrder({ customerId, items, address, note });
      clear();
      onPlaced(order.id);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong.");
    }
  }

  if (items.length === 0) {
    return (
      <section className={styles.empty}>
        <h2>Your basket is empty</h2>
        <p>Add something you like, then come back here to check out.</p>
      </section>
    );
  }

  return (
    <form className={styles.checkout} onSubmit={submit}>
      <h1>Checkout</h1>

      <ul className={styles.items}>
        {items.map((item) => (
          <LineItemRow
            key={item.sku}
            item={item}
            onQuantityChange={(quantity) => setQuantity(item.sku, quantity)}
          />
        ))}
      </ul>

      <AddressForm value={address} onChange={setAddress} />

      <label className={styles.note}>
        Note for the courier
        <textarea value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} />
      </label>

      {error && (
        <p role="alert" className={styles.error}>
          {error}
        </p>
      )}

      <footer className={styles.footer}>
        <span className={styles.total}>Total {formatMoney(total)}</span>
        <button type="submit" className={styles.primary}>
          Place order
        </button>
      </footer>
    </form>
  );
}
"""#

    static let checkoutNew = #"""
import React, { useMemo, useState } from "react";
import { useCart } from "./hooks/useCart";
import { placeOrder } from "./api/orders";
import { formatMoney, sumMoney } from "./format";
import { AddressForm } from "./components/AddressForm";
import { LineItemRow } from "./components/LineItemRow";
import { Spinner } from "./components/Spinner";
import styles from "./Checkout.module.css";

type Props = {
  customerId: string;
  onPlaced: (orderId: string) => void;
};

type SubmitState = "idle" | "submitting" | "failed";

export function Checkout({ customerId, onPlaced }: Props) {
  const { items, setQuantity, clear } = useCart(customerId);
  const [address, setAddress] = useState<Address | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState("");
  const [state, setState] = useState<SubmitState>("idle");

  const total = sumMoney(items.map((item) => item.lineTotal));

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!address) {
      setError("Add a delivery address first.");
      return;
    }
    setState("submitting");
    setError(null);
    try {
      const order = await placeOrder({ customerId, items, address, note });
      clear();
      onPlaced(order.id);
    } catch (err) {
      setState("failed");
      setError(err instanceof Error ? err.message : "Something went wrong.");
    }
  }

  if (items.length === 0) {
    return (
      <section className={styles.empty}>
        <h2>Your cart is empty</h2>
        <p>Add something you like, then come back here to check out.</p>
      </section>
    );
  }

  const isSubmitting = state === "submitting";

  return (
    <form className={styles.checkout} onSubmit={submit} aria-busy={isSubmitting}>
      <h1>Checkout</h1>

      <ul className={styles.items}>
        {items.map((item) => (
          <LineItemRow
            key={item.sku}
            item={item}
            disabled={isSubmitting}
            onQuantityChange={(quantity) => setQuantity(item.sku, quantity)}
          />
        ))}
      </ul>

      <AddressForm value={address} onChange={setAddress} disabled={isSubmitting} />

      <label className={styles.note}>
        Note for the courier
        <textarea value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} />
      </label>

      {error && (
        <p role="alert" className={styles.error}>
          {error}
        </p>
      )}

      <footer className={styles.footer}>
        <span className={styles.total}>Total {formatMoney(total)}</span>
        <button type="submit" className={styles.primary} disabled={isSubmitting}>
          {isSubmitting ? <Spinner label="Placing your order" /> : "Place order"}
        </button>
      </footer>
    </form>
  );
}
"""#

    static let spinner = #"""
import React from "react";
import styles from "./Spinner.module.css";

type Props = {
  /** Read out by screen readers while the spinner shows. */
  label: string;
  size?: "small" | "regular";
};

export function Spinner({ label, size = "small" }: Props) {
  const reduceMotion = usePrefersReducedMotion();
  return (
    <span className={styles.wrapper} role="status" aria-live="polite">
      <span
        className={`${styles.spinner} ${styles[size]}`}
        data-static={reduceMotion || undefined}
        aria-hidden="true"
      />
      <span className={styles.label}>{label}</span>
    </span>
  );
}

function usePrefersReducedMotion(): boolean {
  const query = "(prefers-reduced-motion: reduce)";
  const [matches, setMatches] = React.useState(() => window.matchMedia(query).matches);
  React.useEffect(() => {
    const list = window.matchMedia(query);
    const update = () => setMatches(list.matches);
    list.addEventListener("change", update);
    return () => list.removeEventListener("change", update);
  }, []);
  return matches;
}
"""#

    static let useBasket = #"""
import { useCallback, useEffect, useState } from "react";
import { fetchBasket, saveBasket } from "../api/basket";
import type { BasketItem } from "../types";

export function useBasket(customerId: string) {
  const [items, setItems] = useState<BasketItem[]>([]);

  useEffect(() => {
    let cancelled = false;
    fetchBasket(customerId).then((basket) => {
      if (!cancelled) setItems(basket.items);
    });
    return () => {
      cancelled = true;
    };
  }, [customerId]);

  const setQuantity = useCallback(
    (sku: string, quantity: number) => {
      setItems((current) => {
        const next = current
          .map((item) => (item.sku === sku ? { ...item, quantity } : item))
          .filter((item) => item.quantity > 0);
        saveBasket(customerId, next);
        return next;
      });
    },
    [customerId],
  );

  const clear = useCallback(() => {
    setItems([]);
    saveBasket(customerId, []);
  }, [customerId]);

  return { items, setQuantity, clear };
}
"""#

    static let useCart = #"""
import { useCallback, useEffect, useState } from "react";
import { fetchCart, saveCart } from "../api/cart";
import type { LineItem } from "../types";

export function useCart(customerId: string) {
  const [items, setItems] = useState<LineItem[]>([]);

  useEffect(() => {
    let cancelled = false;
    fetchCart(customerId).then((cart) => {
      if (!cancelled) setItems(cart.items);
    });
    return () => {
      cancelled = true;
    };
  }, [customerId]);

  const setQuantity = useCallback(
    (sku: string, quantity: number) => {
      setItems((current) => {
        const next = current
          .map((item) => (item.sku === sku ? { ...item, quantity } : item))
          .filter((item) => item.quantity > 0);
        saveCart(customerId, next);
        return next;
      });
    },
    [customerId],
  );

  const clear = useCallback(() => {
    setItems([]);
    saveCart(customerId, []);
  }, [customerId]);

  return { items, setQuantity, clear };
}
"""#

    static let seedOrders = #"""
#!/usr/bin/env python3
"""Create a handful of orders in the local API so the checkout pages have data."""

import argparse
import json
import random
import urllib.request

PRODUCTS = [
    ("tea", "Breakfast tea", "3.20"),
    ("scone", "Fruit scone", "2.95"),
    ("jam", "Strawberry jam", "4.50"),
    ("mug", "Enamel mug", "12.00"),
]


def make_order(customer_id: str) -> dict:
    lines = random.sample(PRODUCTS, k=random.randint(1, 3))
    return {
        "customerID": customer_id,
        "items": [
            {"sku": sku, "name": name, "unitPrice": {"amount": price, "currency": "GBP"}, "quantity": random.randint(1, 4)}
            for sku, name, price in lines
        ],
    }


def post(base_url: str, order: dict) -> None:
    request = urllib.request.Request(
        f"{base_url}/v1/orders",
        data=json.dumps(order).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        print(response.status, json.load(response)["id"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://localhost:8080")
    parser.add_argument("--count", type=int, default=5)
    args = parser.parse_args()
    for index in range(args.count):
        post(args.base_url, make_order(f"c_{index:03d}"))
"""#

    static let devScriptOld = #"""
#!/bin/sh
set -eu

# Starts the API and the web app for local checkout work.
PORT="${PORT:-8080}"

echo "Starting API on port $PORT"
swift run ShopAPI --port "$PORT" &
API_PID=$!

trap 'kill $API_PID' EXIT

cd Web
npm run dev -- --port 3000
"""#

    static let devScriptNew = #"""
#!/bin/sh
set -eu

# Starts the API and the web app for local checkout work.
PORT="${PORT:-8080}"
WEB_PORT="${WEB_PORT:-3000}"

echo "Starting API on port $PORT"
swift run ShopAPI --port "$PORT" &
API_PID=$!

trap 'kill $API_PID 2>/dev/null || true' EXIT

if [ "${SEED:-0}" = "1" ]; then
  python3 scripts/seed_orders.py --base-url "http://localhost:$PORT"
fi

cd Web
npm run dev -- --port "$WEB_PORT"
"""#
}
#endif
