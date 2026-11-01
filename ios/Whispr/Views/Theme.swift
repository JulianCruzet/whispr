// FACE: the terminal look. Dark only, black and greys everywhere; colour only ever
// means good (green) or bad (red), never decoration. Readings (times, levels, counts)
// are monospaced with tabular figures. Quiet, fast motion.

import SwiftUI

enum Theme {
    // MARK: Colour

    static let bg = Color(hex: 0x0A0A0A)
    /// Cards, inputs, buttons.
    static let surface = Color(hex: 0x121212)
    /// Raised surface, focused input.
    static let surface2 = Color(hex: 0x181818)
    static let surfaceHover = Color(hex: 0x1F1F1F)
    /// Borders and dividers.
    static let line = Color(hex: 0x232323)
    static let lineStrong = Color(hex: 0x2E2E2E)
    static let text = Color(hex: 0xF4F4F5)
    static let text2 = Color(hex: 0xA1A1AA)
    /// Labels, meta, placeholders.
    static let muted = Color(hex: 0x71717A)
    /// Good: live, saved, cover holding.
    static let up = Color(hex: 0x4CC38A)
    static let upTint = Color(hex: 0x4CC38A).opacity(0.10)
    /// Bad: cover blown, offline, Panic, errors.
    static let down = Color(hex: 0xE5484D)
    static let downTint = Color(hex: 0xE5484D).opacity(0.10)

    // MARK: Type

    /// The line to say: the one big reading on screen.
    static let display = Font.system(size: 30, weight: .medium)
    static let body = Font.system(size: 15)
    static let emphasis = Font.system(size: 15, weight: .medium)
    static let label = Font.system(size: 12, weight: .medium)
    /// Readings and meta: timestamps, levels, counts.
    static let meta = Font.system(size: 12, design: .monospaced).monospacedDigit()

    // MARK: Motion

    /// Content fades in over 180 ms with a 2 pt rise.
    static let appear = Animation.easeOut(duration: 0.18)
    static let rise: AnyTransition = .opacity.combined(with: .offset(y: 2))
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

/// A small label: 12 pt medium, muted.
struct LabelText: View {
    let text: String
    var color: Color = Theme.muted

    init(_ text: String, color: Color = Theme.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(color)
    }
}

/// A reading: monospaced, tabular, muted.
struct MetaText: View {
    let text: String
    var color: Color = Theme.muted

    init(_ text: String, color: Color = Theme.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Theme.meta)
            .foregroundStyle(color)
    }
}

/// Pill buttons. Primary is inverted (light fill, dark text); the rest sit on the surface.
/// Main actions are 44 pt tall to stay easy to hit mid-conversation; small ones 36 pt.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, alarm }
    var kind: Kind = .secondary
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: height > 40 ? 15 : 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var pressed: Bool { configuration.isPressed }

    private var fill: Color {
        switch kind {
        case .primary: pressed ? Color(hex: 0xE4E4E7) : Theme.text
        case .secondary: pressed ? Theme.surfaceHover : Theme.surface
        case .alarm: pressed ? Theme.down.opacity(0.18) : Theme.downTint
        }
    }

    private var border: Color {
        switch kind {
        case .primary: .clear
        case .secondary: pressed ? Theme.lineStrong : Theme.line
        case .alarm: Theme.down.opacity(0.45)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.bg
        case .secondary: Theme.text
        case .alarm: Theme.down
        }
    }
}

/// A card: 16 pt radius, surface fill, hairline border.
struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Status dot. When `pulsing`, a soft halo grows 0.6x to 1.7x and fades on a 2.4 s loop.
struct PulsingDot: View {
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                    Circle()
                        .fill(color.opacity(0.45 * (1 - phase)))
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.6 + 1.1 * phase)
                }
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}
