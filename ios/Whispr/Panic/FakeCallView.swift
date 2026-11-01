// PANIC (owner: Julian + Claude)
// Full-screen fake incoming call, styled like the iOS call screen, then a fake
// in-call screen once answered. Used when "Use iOS call screen" is off (the default:
// it always shows full screen, unlike CallKit's banner when the phone is in use).

import SwiftUI

struct FakeCallView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Spacer().frame(height: 70)
                Text(model.panicCallerName)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                subtitle
                Spacer()
                if case .inCall = model.panic {
                    inCallControls
                } else {
                    ringingControls
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
        }
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var subtitle: some View {
        if case let .inCall(since) = model.panic {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Self.duration(from: since, to: context.date))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else {
            Text("mobile")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var ringingControls: some View {
        HStack {
            CallButton(systemImage: "phone.down.fill", color: .red, label: "Decline") {
                model.endFakeCall()
            }
            Spacer()
            CallButton(systemImage: "phone.fill", color: .green, label: "Accept") {
                model.answerFakeCall()
            }
        }
    }

    private var inCallControls: some View {
        VStack(spacing: 40) {
            HStack(spacing: 28) {
                ForEach(["mic.slash.fill", "circle.grid.3x3.fill", "speaker.wave.3.fill"], id: \.self) { icon in
                    Image(systemName: icon)
                        .font(.title2)
                        .frame(width: 76, height: 76)
                        .background(.white.opacity(0.15), in: Circle())
                        .foregroundStyle(.white)
                }
            }
            CallButton(systemImage: "phone.down.fill", color: .red, label: "End") {
                model.endFakeCall()
            }
        }
    }

    private static func duration(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CallButton: View {
    let systemImage: String
    let color: Color
    let label: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
                    .background(color, in: Circle())
            }
            Text(label)
                .font(.callout)
                .foregroundStyle(.white)
        }
    }
}
