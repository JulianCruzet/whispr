// FACE: the "Savile Row" look. Whispr is the voice in a Kingsman's earpiece, so the
// app dresses like the tailor shop out front: worsted navy with a chalk pinstripe,
// brass fittings, and an oxblood silk lining for the line you're about to say.

import SwiftUI

enum Theme {
    // MARK: Colour

    /// Worsted navy: the cloth. Background.
    static let worsted = Color(hex: 0x0F1626)
    /// Pinstripe: hairlines and quiet surfaces.
    static let pinstripe = Color(hex: 0x1F2839)
    /// Chalk: primary text.
    static let chalk = Color(hex: 0xEDE8DF)
    /// Smoke: secondary text, the wearer's own lines.
    static let smoke = Color(hex: 0x8F98A9)
    /// Brass: buttons, buckles, anything you can act on.
    static let brass = Color(hex: 0xC9A55C)
    /// Oxblood: the lining (the whisper card) and Panic.
    static let oxblood = Color(hex: 0x6B1C27)
    static let oxbloodDeep = Color(hex: 0x45111A)
    static let alarm = Color(hex: 0xA8323F)

    // MARK: Type

    /// Didot, the fashion-house serif: the whispered line and the wordmark.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("Didot", size: size, relativeTo: style)
    }

    static func displayItalic(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("Didot-Italic", size: size, relativeTo: style)
    }

    /// Small monospaced caps for labels, status and data, like a tailor's ticket.
    static let ticket = Font.system(.caption2, design: .monospaced).weight(.semibold)
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

/// Ticket-style label: monospaced caps with a little tracking.
struct TicketText: View {
    let text: String
    var color: Color = Theme.smoke

    init(_ text: String, color: Color = Theme.smoke) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.ticket)
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

/// Worsted navy with a faint chalk pinstripe, edge to edge.
struct PinstripeBackground: View {
    var body: some View {
        Theme.worsted
            .overlay {
                Canvas { context, size in
                    let spacing: CGFloat = 14
                    var x: CGFloat = spacing / 2
                    while x < size.width {
                        context.fill(
                            Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)),
                            with: .color(Theme.chalk.opacity(0.045))
                        )
                        x += spacing
                    }
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// The jacket lining: oxblood silk with a brass running stitch just inside the edge.
struct LiningBackground: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [Theme.oxblood, Theme.oxbloodDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius - 6, style: .continuous)
                    .inset(by: 7)
                    .stroke(Theme.brass.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
    }
}

/// The woven label sewn into the lining.
struct WovenLabel: View {
    let text: String

    var body: some View {
        TicketText(text, color: Theme.brass)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.worsted, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Theme.brass.opacity(0.4), lineWidth: 0.5))
    }
}

/// Brass capsule for the main action; outline variant for secondary ones.
struct BrassButtonStyle: ButtonStyle {
    var filled = true
    var fill: Color = Theme.brass

    func makeBody(configuration: Configuration) -> some View {
        BrassButtonBody(configuration: configuration, filled: filled, fill: fill)
    }
}

private struct BrassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let filled: Bool
    let fill: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(filled ? (fill == Theme.brass ? Theme.worsted : Theme.chalk) : Theme.brass)
            .background {
                if filled {
                    Capsule().fill(fill)
                } else {
                    Capsule().stroke(Theme.brass.opacity(0.7), lineWidth: 1)
                }
            }
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
