// FACE: a calm, editorial look in the spirit of Wealthsimple: warm paper canvas,
// graphite type, a serif for the things that matter, black pill buttons, hairlines
// instead of shadows. The line to say sits on a dark bronze panel, the one dark
// object on the screen, so it's the first thing the eye lands on.

import SwiftUI

enum Theme {
    // MARK: Colour

    /// Page canvas.
    static let paper = Color(hex: 0xFCFCFC)
    /// Warm wash for quiet surfaces (pills, the calibrate button).
    static let linen = Color(hex: 0xF4F1EC)
    /// Hairline borders and dividers.
    static let stone = Color(hex: 0xE4E2E1)
    /// Primary text.
    static let graphite = Color(hex: 0x32302F)
    /// Secondary text and the wearer's own lines.
    static let pebble = Color(hex: 0x686664)
    /// Primary buttons.
    static let charcoal = Color(hex: 0x09090A)
    /// The panel for the line to say.
    static let bronze = Color(hex: 0x3A3525)
    /// Text on the bronze panel.
    static let cream = Color(hex: 0xF6F1E7)
    /// Panic and warnings: the only strong colour, kept for the escape hatch.
    static let brick = Color(hex: 0xA33A2B)
    /// "Live" and "saved" confirmations.
    static let moss = Color(hex: 0x3E7A52)

    // MARK: Type

    /// Editorial serif (iOS's New York) for the wordmark and the line to say.
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif).weight(weight)
    }

    /// Small UI labels: sentence case with a touch of tracking.
    static let label = Font.footnote.weight(.medium)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A small sentence-case label.
struct LabelText: View {
    let text: String
    var color: Color = Theme.pebble

    init(_ text: String, color: Color = Theme.pebble) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Theme.label)
            .tracking(0.2)
            .foregroundStyle(color)
    }
}

/// Pill buttons: filled charcoal (primary), outlined (secondary), linen (quiet), or a custom fill.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, alarm }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.body.weight(.medium))
            .tracking(0.3)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .foregroundStyle(foreground)
            .background {
                switch kind {
                case .primary: Capsule().fill(Theme.charcoal)
                case .alarm: Capsule().fill(Theme.brick)
                case .quiet: Capsule().fill(Theme.linen)
                case .secondary: Capsule().strokeBorder(Theme.graphite, lineWidth: 1)
                }
            }
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .alarm: Theme.paper
        case .secondary, .quiet: Theme.graphite
        }
    }
}
