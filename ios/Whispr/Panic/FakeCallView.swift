// PANIC (owner: Julian + Claude)
// Full-screen fake call, styled like the current iOS call screen: frosted colour
// backdrop, big name, glass initials, slide to answer. Opens from the app's own banner
// or pill, and after answering on CallKit, so tapping the system pill lands on the call.
//
// CallIslandOverlay is that banner and pill. Answering a CallKit call hands the screen to
// iOS, so while Whispr is open the app draws the call around the Dynamic Island itself.

import SwiftUI
import UIKit

struct FakeCallView: View {
    @Environment(AppModel.self) private var model
    @State private var speakerOn = false
    @State private var muted = false

    private var since: Date? {
        if case let .inCall(since) = model.panic { return since }
        return nil
    }

    private var nameParts: (first: String, rest: String) {
        let words = model.panicCallerName.split(separator: " ").map(String.init)
        return (words.first ?? "", words.dropFirst().joined(separator: " "))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CallBackdrop()

            VStack(spacing: 0) {
                if let since {
                    timer(since)
                    Text(nameParts.first)
                        .font(.system(size: 52, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                } else {
                    ringingName
                }
                Spacer(minLength: 16)
                InitialsCircle(initials: model.panicCallerName.callInitials)
                Spacer(minLength: 16)
                if since != nil {
                    inCallControls
                } else {
                    ringingControls
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 24)

            if !model.panicOnCallKit {
                Button {
                    model.minimizeCallScreen()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Minimize call")
                .padding(.leading, 12)
            }
        }
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
    }

    private var ringingName: some View {
        VStack(spacing: 0) {
            Text(nameParts.first)
                .font(.system(size: nameParts.rest.isEmpty ? 64 : 44, weight: .regular))
            if !nameParts.rest.isEmpty {
                Text(nameParts.rest)
                    .font(.system(size: 64, weight: .regular))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    private func timer(_ since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Self.duration(from: since, to: context.date))
                .font(.title2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var ringingControls: some View {
        VStack(spacing: 36) {
            HStack {
                SmallCallButton(systemImage: "message.fill", label: "Message") { model.endFakeCall() }
                Spacer()
                SmallCallButton(systemImage: "recordingtape", label: "Voicemail") { model.endFakeCall() }
            }
            .padding(.horizontal, 8)
            SlideToAnswer { model.answerFakeCall() }
        }
    }

    private var inCallControls: some View {
        Grid(horizontalSpacing: 28, verticalSpacing: 24) {
            GridRow {
                CallControl(systemImage: "speaker.wave.3.fill", label: "Speaker", isOn: speakerOn) { speakerOn.toggle() }
                CallControl(systemImage: "video.fill", label: "FaceTime") {}
                CallControl(systemImage: "mic.slash.fill", label: "Mute", isOn: muted) { muted.toggle() }
            }
            GridRow {
                CallControl(systemImage: "ellipsis", label: "More") {}
                CallControl(systemImage: "phone.down.fill", label: "End", fill: Self.endRed) { model.endFakeCall() }
                CallControl(systemImage: "circle.grid.3x3.fill", label: "Keypad") {}
            }
        }
    }

    private static let endRed = Color(hex: 0xD00000)

    fileprivate static func duration(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private extension String {
    var callInitials: String {
        split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// The app's own call banner and pill, drawn around the Dynamic Island, or just below the
/// status bar on phones without one.
struct CallIslandOverlay: View {
    @Environment(AppModel.self) private var model

    private static let islandWidth: CGFloat = 126
    private static let islandHeight: CGFloat = 37
    private static let bannerHeight: CGFloat = 84

    /// Apps can't ask for the Dynamic Island directly, but its phones have the tallest top inset.
    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 0
    }

    private var hasIsland: Bool { topInset >= 59 }

    /// The Island sits about 48 points above the bottom of the top inset.
    private var islandTop: CGFloat { max(0, topInset - 48) }

    var body: some View {
        VStack(spacing: 0) {
            if model.showsCallBanner {
                banner
                    .padding(.top, hasIsland ? islandTop : topInset + 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let since = model.callPillSince {
                pill(since: since)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
        .animation(.spring(duration: 0.35), value: model.showsCallBanner)
        .animation(.spring(duration: 0.35), value: model.callPillSince)
    }

    private var banner: some View {
        HStack(spacing: 12) {
            Button {
                model.openCallScreen()
            } label: {
                HStack(spacing: 12) {
                    Text(model.panicCallerName.callInitials)
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 52, height: 52)
                        .background(Color(white: 0.3), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("mobile")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(model.panicCallerName)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Open call from \(model.panicCallerName)")
            BannerButton(systemImage: "phone.down.fill", color: .red, label: "Decline") { model.endFakeCall() }
            BannerButton(systemImage: "phone.fill", color: .green, label: "Accept") { model.answerFakeCall() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: Self.bannerHeight)
        .background(.black, in: RoundedRectangle(cornerRadius: Self.bannerHeight / 2.4, style: .continuous))
        .padding(.horizontal, 10)
    }

    @ViewBuilder private func pill(since: Date) -> some View {
        Button {
            model.openCallScreen()
        } label: {
            if hasIsland {
                HStack(spacing: Self.islandWidth + 8) {
                    // Equal sides keep the pill centred on the camera cut-out.
                    pillTimer(since: since, color: .green)
                        .frame(width: 60, alignment: .leading)
                    CallWaveform()
                        .frame(width: 26, height: 16)
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .frame(height: Self.islandHeight)
                .background(.black, in: Capsule())
            } else {
                pillTimer(since: since, color: .white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.green, in: Capsule())
            }
        }
        .accessibilityLabel("Return to call")
        .padding(.top, hasIsland ? islandTop : topInset + 4)
    }

    private func pillTimer(since: Date, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "phone.fill")
                .font(.system(size: 12))
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(FakeCallView.duration(from: since, to: context.date))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(color)
    }
}

private struct BannerButton: View {
    let systemImage: String
    let color: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(color, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

/// The little green bars the Island shows during a call.
private struct CallWaveform: View {
    private static let bars = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<Self.bars, id: \.self) { bar in
                    Capsule()
                        .fill(.green)
                        .frame(width: 3)
                        .scaleEffect(y: 0.4 + 0.6 * abs(sin(time * 3 + Double(bar) * 0.9)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The soft grey-to-violet wash iOS puts behind a caller with no contact photo.
private struct CallBackdrop: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0x93A3A7), location: 0),
                .init(color: Color(hex: 0x76808F), location: 0.28),
                .init(color: Color(hex: 0x41345A), location: 0.55),
                .init(color: Color(hex: 0x1C1838), location: 0.78),
                .init(color: Color(hex: 0x1E1C2C), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay {
            RadialGradient(colors: [Color(hex: 0x14184A).opacity(0.7), .clear], center: .trailing, startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }
}

/// A big frosted disc with the caller's initials and a light catching its rim.
private struct InitialsCircle: View {
    let initials: String

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
            .overlay {
                Circle().strokeBorder(
                    AngularGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.05), .white.opacity(0.4), .white.opacity(0.05), .white.opacity(0.55)],
                        center: .center,
                        angle: .degrees(-45)
                    ),
                    lineWidth: 1.5
                )
            }
            .overlay {
                GeometryReader { proxy in
                    Text(initials)
                        .font(.system(size: proxy.size.width * 0.38, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
    }
}

/// Slide the white knob across to pick up, as on the lock screen.
private struct SlideToAnswer: View {
    let onAnswer: () -> Void
    @State private var offset: CGFloat = 0
    @State private var answered = false

    private let height: CGFloat = 88
    private let inset: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let knob = height - inset * 2
            let travel = max(1, proxy.size.width - knob - inset * 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.1))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))

                Text("slide to answer")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob)
                    .opacity(1 - offset / travel)

                Image(systemName: "phone.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                    .frame(width: knob, height: knob)
                    .background(.white, in: Circle())
                    .padding(.leading, inset)
                    .offset(x: offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                offset = min(travel, max(0, value.translation.width))
                            }
                            .onEnded { _ in
                                if offset > travel * 0.75 {
                                    offset = travel
                                    answered = true
                                    onAnswer()
                                } else {
                                    withAnimation(.spring(duration: 0.3)) { offset = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: height)
        .sensoryFeedback(.success, trigger: answered)
    }
}

/// In-call control: a glass circle, white while switched on.
private struct CallControl: View {
    let systemImage: String
    let label: String
    var isOn = false
    var fill: Color?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(isOn ? Color(hex: 0x1C1838) : .white)
                    .frame(width: 80, height: 80)
                    .background(fill ?? (isOn ? .white : .white.opacity(0.12)), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            }
            Text(label)
                .font(.subheadline)
        }
    }
}

/// The small Message and Voicemail buttons above the slider. Either one dismisses the call.
private struct SmallCallButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            }
            Text(label)
                .font(.subheadline)
        }
    }
}
