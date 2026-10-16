import SwiftUI

/// A thread's state as a symbol and words. Colour only repeats what the words say.
struct ThreadStateChip: View {
    let state: ThreadState

    var body: some View {
        Chip(text: state.label, symbol: state.symbol, tint: state.tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("State: \(state.label)")
    }
}

struct LayerStatusChip: View {
    let status: LayerStatus

    var body: some View {
        if let label = status.label {
            Chip(text: label, symbol: status.symbol, tint: status.tint, isSmall: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Status: \(label)")
        }
    }
}

struct Chip: View {
    let text: String
    let symbol: String?
    let tint: Color
    var isSmall = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(isSmall ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, isSmall ? 6 : 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

extension ThreadState {
    var symbol: String {
        switch self {
        case .resolved: "checkmark.circle.fill"
        case .draft: "pencil"
        case .agentAsks: "questionmark.bubble.fill"
        case .checkTheFix: "wrench.and.screwdriver.fill"
        case .agentDeclined: "hand.raised.fill"
        case .waitingOnAgent: "hourglass"
        }
    }

    var tint: Color {
        switch self {
        case .resolved: .secondary
        case .draft: .yellow
        case .agentAsks: .orange
        case .checkTheFix: .green
        case .agentDeclined: .red
        case .waitingOnAgent: .blue
        }
    }

    /// Sorts the threads list: what needs you first, finished threads last.
    var listOrder: Int {
        switch self {
        case .agentAsks: 0
        case .checkTheFix: 1
        case .agentDeclined: 2
        case .draft: 3
        case .waitingOnAgent: 4
        case .resolved: 5
        }
    }
}

extension LayerStatus {
    var label: String? {
        switch self {
        case .ready: nil
        case .needsRestack: "Needs restack"
        case .merged: "Merged"
        case .empty: "Empty"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark"
        case .needsRestack: "arrow.triangle.2.circlepath"
        case .merged: "arrow.triangle.merge"
        case .empty: "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .secondary
        case .needsRestack: .orange
        case .merged: .purple
        case .empty: .secondary
        }
    }
}

extension Author {
    var name: String {
        switch self {
        case .you(let name), .agent(let name): name
        }
    }

    var isAgent: Bool {
        if case .agent = self { true } else { false }
    }
}

/// A 24-point avatar: your initials, or a sparkles symbol for the agent.
struct AvatarView: View {
    let author: Author

    var body: some View {
        ZStack {
            Circle().fill(fill)
            if author.isAgent {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var fill: LinearGradient {
        let colors: [Color] = author.isAgent
            ? [Color(red: 0.89, green: 0.52, blue: 0.40), Color(red: 0.78, green: 0.40, blue: 0.30)]
            : [Color.accentColor.opacity(0.85), Color.accentColor]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var initials: String {
        let words = author.name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

enum RelativeTime {
    @MainActor private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    @MainActor
    static func text(for date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 45 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
