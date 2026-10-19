import SwiftUI

/// Design tokens (colours, type, motion) for SwiftUI.
enum UIStyle {
    static let bg = Color(hex: 0x07070A)
    static let surface = Color(hex: 0x0D0D12)
    static let surface2 = Color(hex: 0x15151C)
    static let surface3 = Color(hex: 0x1F1F28)
    static let ink = Color(hex: 0xF5F1EA)
    static let inkDim = ink.opacity(0.62)
    static let inkFaint = ink.opacity(0.14)
    static let line = ink.opacity(0.10)
    static let accent = Color(hex: 0x7DF9FF)
    static let accent2 = Color(hex: 0xB8B4FF)
    static let accent3 = Color(hex: 0xFF5A8C)

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Manrope", size: size).weight(weight)
    }
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", size: size).weight(weight)
    }

    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
    static let easeSlow = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.9)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Mono, uppercase, tracked-out label — the Style "eyebrow".
struct Eyebrow: View {
    let text: String
    var color: Color = UIStyle.inkDim
    init(_ text: String, color: Color = UIStyle.inkDim) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(UIStyle.mono(10, .medium))
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

/// Dark glass panel with a hairline border.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(UIStyle.surface.opacity(0.82))
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(UIStyle.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
    }
}

extension View {
    func glassPanel(radius: CGFloat = 20) -> some View { modifier(GlassPanel(radius: radius)) }
}

/// Round icon button used for transport controls.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 34
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(prominent ? UIStyle.bg : UIStyle.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(prominent ? UIStyle.ink : (hovering ? UIStyle.inkFaint : Color.clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(UIStyle.ease, value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Timbre additions

/// Pill-shaped toggle chip.
struct Chip: View {
    let title: String
    var symbol: String?
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(UIStyle.sans(12, .semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(active ? UIStyle.bg : UIStyle.ink)
            .background(Capsule().fill(active ? UIStyle.accent : (hovering ? UIStyle.surface3 : UIStyle.surface2)))
            .overlay(Capsule().strokeBorder(active ? Color.clear : UIStyle.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(UIStyle.ease, value: active)
    }
}

/// Primary / secondary text button.
struct AppButton: View {
    let title: String
    var symbol: String?
    var style: Style = .secondary
    let action: () -> Void
    enum Style { case primary, secondary, quiet }
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(UIStyle.sans(12.5, .semibold))
            }
            .padding(.horizontal, style == .quiet ? 8 : 14).padding(.vertical, 8)
            .foregroundStyle(style == .primary ? UIStyle.bg : (style == .quiet ? UIStyle.inkDim : UIStyle.ink))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style == .primary ? UIStyle.accent : (style == .quiet ? (hovering ? UIStyle.surface2 : .clear) : (hovering ? UIStyle.surface3 : UIStyle.surface2)))
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style == .secondary ? UIStyle.line : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .brightness(style == .primary && hovering ? 0.06 : 0)
    }
}

/// Big on/off switch with glow when on.
struct PowerSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { withAnimation(UIStyle.ease) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? UIStyle.accent : UIStyle.surface3)
                    .overlay(Capsule().strokeBorder(isOn ? .clear : UIStyle.line))
                    .shadow(color: isOn ? UIStyle.accent.opacity(0.55) : .clear, radius: 14)
                Circle().fill(isOn ? UIStyle.bg : UIStyle.ink).padding(4)
                    .overlay(Image(systemName: "power").font(.system(size: 10, weight: .bold)).foregroundStyle(isOn ? UIStyle.accent : UIStyle.bg))
            }
            .frame(width: 58, height: 32)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Turn the EQ off (⌃⌥⌘E)" : "Turn the EQ on (⌃⌥⌘E)")
    }
}

/// Small explanatory text used under headings.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(UIStyle.sans(12.5)).foregroundStyle(UIStyle.inkDim).fixedSize(horizontal: false, vertical: true)
    }
}

enum Format {
    static func hz(_ f: Double) -> String {
        if f >= 1000 {
            let k = f / 1000
            return String(format: "%.3g", k) + "k"
        }
        return f < 100 ? String(format: "%.3g", f) : String(format: "%.0f", f)
    }
    static func db(_ g: Double) -> String {
        let v = (g * 10).rounded() / 10
        return (v > 0 ? "+" : "") + String(format: "%.1f", v)
    }
}
