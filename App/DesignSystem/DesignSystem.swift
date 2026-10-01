import SwiftUI

/// Semantic design tokens. All colors resolve via the system so dark mode
/// and accessibility settings are honored automatically; typography uses the
/// Dynamic Type text styles (no fixed point sizes).
enum DS {
    enum Color {
        static let background = SwiftUI.Color(.systemBackground)
        static let secondaryBackground = SwiftUI.Color(.secondarySystemBackground)
        static let label = SwiftUI.Color(.label)
        static let secondaryLabel = SwiftUI.Color(.secondaryLabel)
        static let accent = SwiftUI.Color.accentColor
        static let good = SwiftUI.Color.green
        static let warning = SwiftUI.Color.orange
        static let bad = SwiftUI.Color.red
    }

    enum Typography {
        static let title = Font.title2.weight(.semibold)
        static let headline = Font.headline
        static let body = Font.body
        static let caption = Font.caption
        static let metric = Font.largeTitle.weight(.bold).monospacedDigit()
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 14
    }
}

/// Rounded material card container used across the app.
struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.secondaryBackground,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

/// Label + value row for device metrics.
struct MetricRow: View {
    let title: String
    let value: String
    var systemImage: String? = nil
    var valueColor: Color = DS.Color.label

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(DS.Color.secondaryLabel)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.secondaryLabel)
            Spacer()
            Text(value)
                .font(DS.Typography.body.monospacedDigit())
                .foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Circular gauge for the 0–1000 AI performance index.
struct ScoreGauge: View {
    let score: Int?
    var max: Int = 1000

    private var fraction: Double {
        guard let score else { return 0 }
        return min(1, max(0, Double(score) / Double(max)))
    }

    private var tint: Color {
        switch fraction {
        case ..<0.33: return DS.Color.bad
        case ..<0.66: return DS.Color.warning
        default: return DS.Color.good
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.Color.secondaryLabel.opacity(0.2), lineWidth: 12)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.default, value: fraction)
            VStack(spacing: DS.Spacing.xs) {
                if let score {
                    Text(score, format: .number)
                        .font(DS.Typography.metric)
                } else {
                    Text("–")
                        .font(DS.Typography.metric)
                        .foregroundStyle(DS.Color.secondaryLabel)
                }
                Text(String(localized: "gauge.caption"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryLabel)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "gauge.accessibility"))
        .accessibilityValue(score.map { "\($0) / \(max)" } ?? String(localized: "gauge.unmeasured"))
    }
}
