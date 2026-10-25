import SwiftUI

/// The 1.1 look of the Mac app: a teal → indigo → violet brand gradient,
/// translucent cards on top of it, and coloured icon badges (D-104).
enum Brand {
    static let teal = Color(red: 0.05, green: 0.66, blue: 0.68)
    static let indigo = Color(red: 0.30, green: 0.36, blue: 0.93)
    static let violet = Color(red: 0.62, green: 0.32, blue: 0.92)
    static let pink = Color(red: 0.93, green: 0.36, blue: 0.62)

    static let gradient = LinearGradient(colors: [teal, indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let buttonGradient = LinearGradient(colors: [teal, indigo], startPoint: .leading, endPoint: .trailing)
}

/// Soft, blurred colour blobs behind a window's content.
struct BrandBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var intensity: Double = 1

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    blob(Brand.teal, diameter: size.width * 0.9)
                        .offset(x: -size.width * 0.35, y: -size.height * 0.35)
                    blob(Brand.indigo, diameter: size.width * 0.8)
                        .offset(x: size.width * 0.4, y: -size.height * 0.1)
                    blob(Brand.violet, diameter: size.width * 0.9)
                        .offset(x: -size.width * 0.1, y: size.height * 0.45)
                }
                .frame(width: size.width, height: size.height)
            }
            .blur(radius: 60)
            .opacity((colorScheme == .dark ? 0.45 : 0.28) * intensity)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func blob(_ color: Color, diameter: CGFloat) -> some View {
        Circle().fill(color).frame(width: diameter, height: diameter)
    }
}

extension View {
    /// A translucent rounded card that lets the brand background through.
    func glassCard(cornerRadius: CGFloat = 14, padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}

/// A white SF Symbol on a gradient rounded square (settings sidebar, headers).
struct IconBadge: View {
    let symbol: String
    var colors: [Color] = [Brand.teal, Brand.indigo]
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// The large call-to-action button: gradient capsule, white label.
struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Brand.buttonGradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Small coloured status pill, e.g. "Running".
struct StatusPill: View {
    let text: Text
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            text
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.18), in: Capsule())
    }
}

/// A slim usage bar, green → orange → red.
struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private var color: Color {
        fraction >= 0.9 ? .red : (fraction >= 0.7 ? .orange : Brand.teal)
    }
}
