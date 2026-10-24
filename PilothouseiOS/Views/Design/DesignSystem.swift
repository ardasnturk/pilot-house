import PilothouseKit
import SwiftUI

/// Shared look of the iOS app: card radii, agent identity, floating surfaces.
enum Design {
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 12
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let insetBackground = Color(.tertiarySystemFill)
}

extension AgentKind {
    /// SF Symbol that stands for the agent everywhere in the app.
    var symbol: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gemini: "diamond"
        default: "person.crop.square"
        }
    }

    var tint: Color {
        switch self {
        case .claude: .accentColor
        case .codex: .indigo
        case .gemini: .teal
        default: .gray
        }
    }
}

/// Rounded square with the agent's symbol, or the session's state when that matters more.
struct AgentAvatar: View {
    enum Emphasis {
        case agent
        case approval
        case done
    }

    let agent: AgentKind
    var emphasis: Emphasis = .agent
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(foreground)
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch emphasis {
        case .agent: agent.symbol
        case .approval: "hand.raised.fill"
        case .done: "checkmark"
        }
    }

    private var foreground: Color {
        switch emphasis {
        case .agent: agent.tint
        case .approval: .orange
        case .done: .secondary
        }
    }

    private var background: Color {
        switch emphasis {
        case .agent: agent.tint.opacity(0.14)
        case .approval: Color.orange.opacity(0.16)
        case .done: Design.insetBackground
        }
    }
}

extension View {
    /// A floating control surface: Liquid Glass on iOS 26, a material capsule before.
    @ViewBuilder func floatingSurface<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
        }
    }

    /// Card background used for grouped content outside of `List`.
    func cardBackground(cornerRadius: CGFloat = Design.cardRadius) -> some View {
        background(Design.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Small rounded label, e.g. "running" or a model name.
struct Chip: View {
    let text: Text
    var tint: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            text
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - 1.1 look (D-104)

/// Brand colours shared with the Mac app: teal → indigo → violet.
enum Brand {
    static let teal = Color(red: 0.05, green: 0.66, blue: 0.68)
    static let indigo = Color(red: 0.30, green: 0.36, blue: 0.93)
    static let violet = Color(red: 0.62, green: 0.32, blue: 0.92)
    static let pink = Color(red: 0.93, green: 0.36, blue: 0.62)

    static let gradient = LinearGradient(colors: [teal, indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let bubbleGradient = LinearGradient(colors: [teal, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The app's background: a soft mesh of the brand colours behind everything.
struct GradientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    /// 1 on overview screens, lower behind long text (chat).
    var intensity: Double = 1

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.6, 0.45], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: colors
            )
            .opacity((colorScheme == .dark ? 0.55 : 0.32) * intensity)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var colors: [Color] {
        let base = colorScheme == .dark ? Color.black : Color.white
        return [
            Brand.teal, Brand.indigo.opacity(0.8), Brand.violet,
            base, Brand.teal.opacity(0.35), Brand.pink.opacity(0.5),
            base, base, Brand.indigo.opacity(0.45),
        ]
    }
}

extension View {
    /// The gradient background for a screen; lists and forms let it through.
    func gradientBackground(intensity: Double = 1) -> some View {
        scrollContentBackground(.hidden)
            .background(GradientBackground(intensity: intensity))
    }

    /// A translucent card on top of the gradient.
    func glassCard(cornerRadius: CGFloat = Design.cardRadius) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

/// Primary call to action: a gradient capsule with white text.
struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(Brand.bubbleGradient, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A white SF Symbol on a gradient rounded square.
struct IconBadge: View {
    let symbol: String
    var colors: [Color] = [Brand.teal, Brand.indigo]
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
