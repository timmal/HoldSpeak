import SwiftUI
import AppKit

enum PTT {
    // MARK: - Surfaces

    static func popoverBG(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 23/255, green: 23/255, blue: 31/255).opacity(0.95) : .white
    }
    static func prefsBG(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 18/255, green: 18/255, blue: 26/255).opacity(0.98) : .white
    }
    static func cardBG(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04)
    }
    static func cardBorder(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
    static func surfaceBorder(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
    static func divider(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
    static func fieldBG(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
    static func fieldBorder(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }
    static func headerStrip(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.03)
    }
    static func segmentBG(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05)
    }
    static func segmentSelected(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }
    static func buttonBG(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    // MARK: - Text

    static func textPrimary(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.95, green: 0.95, blue: 0.98) : Color(red: 0.03, green: 0.03, blue: 0.06)
    }
    static func textBody(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.92, green: 0.92, blue: 0.94) : Color(red: 0.07, green: 0.07, blue: 0.09)
    }
    static func textMuted(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.65, green: 0.65, blue: 0.71) : Color(red: 0.32, green: 0.32, blue: 0.37)
    }
    static func textSoft(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.55, green: 0.55, blue: 0.60) : Color(red: 0.42, green: 0.42, blue: 0.47)
    }
    static func textCaption(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.50, green: 0.50, blue: 0.55) : Color(red: 0.47, green: 0.47, blue: 0.52) // #80808c / #777784
    }

    // MARK: - Accents

    static func accentLink(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.55, green: 0.75, blue: 1.0) : Color(red: 0.15, green: 0.38, blue: 0.95)
    }
    static func trendUp(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.45, green: 0.85, blue: 0.60) : Color(red: 0.10, green: 0.55, blue: 0.30)
    }
    static func trendDown(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 1.0, green: 0.55, blue: 0.55) : Color(red: 0.80, green: 0.20, blue: 0.25)
    }
    static let recordingRed = Color(red: 0.95, green: 0.24, blue: 0.32)
    static let statusGreen = Color(red: 0.22, green: 0.80, blue: 0.45)
}

/// NSVisualEffectView backing for popovers / prefs window.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

// MARK: - Liquid Glass
//
// macOS 26+ draws these as Liquid Glass; older systems keep the flat look.

extension View {
    /// Glass in `glass` on macOS 26+, otherwise a `fill` in `fallback` with an optional hairline.
    @ViewBuilder
    func pttSurface<G: Shape, F: Shape>(
        glass: G, fallback: F, fill: Color, border: Color? = nil,
        tint: Color? = nil, interactive: Bool = false
    ) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: glass)
        } else {
            background(fallback.fill(fill))
                .overlay { if let border { fallback.stroke(border, lineWidth: 1) } }
        }
    }

    /// Muted text. On glass a fixed grey washes out against whatever is behind the
    /// panel, so macOS 26+ uses the vibrant hierarchical style instead.
    @ViewBuilder
    func pttMuted(_ fallback: Color, level: HierarchicalLevel = .secondary) -> some View {
        if #available(macOS 26, *) {
            switch level {
            case .secondary: foregroundStyle(.secondary)
            case .tertiary:  foregroundStyle(.tertiary)
            }
        } else {
            foregroundColor(fallback)
        }
    }

    /// Secondary push button: glass on macOS 26+, the bordered pill elsewhere.
    @ViewBuilder
    func pttButton() -> some View {
        let styled = font(.system(size: 13, weight: .medium))
        if #available(macOS 26, *) {
            // The glass style dims an unstyled label; a label's own colour (red) still wins.
            styled.foregroundStyle(.primary).buttonStyle(.glass)
        } else {
            styled.buttonStyle(PTTBorderedButtonStyle())
        }
    }

    /// Primary action button.
    @ViewBuilder
    func pttProminentButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Small toolbar-like button: glass on macOS 26+, bare label elsewhere.
    @ViewBuilder
    func pttQuietButton(circle: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if circle {
                buttonStyle(.glass).buttonBorderShape(.circle)
            } else {
                buttonStyle(.glass)
            }
        } else {
            buttonStyle(.plain)
        }
    }
}

enum HierarchicalLevel { case secondary, tertiary }

struct PTTBorderedButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(PTT.textPrimary(scheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(PTT.buttonBG(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PTT.fieldBorder(scheme), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
            .contentShape(Rectangle())
    }
}
