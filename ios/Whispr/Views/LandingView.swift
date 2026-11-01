import SwiftUI

/// Decides what opens: the app if you're signed in, otherwise the landing page.
struct RootView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        Group {
            if auth.isSignedIn {
                ContentView()
            } else {
                LandingView()
            }
        }
        .task { await auth.refreshIfSignedIn() }
    }
}

/// The first thing a signed-out person sees: what Whispr does, then the way in.
struct LandingView: View {
    private enum Mode: Identifiable {
        case signUp, signIn
        var id: Self { self }
    }

    @State private var mode: Mode?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("Whispr")
                .font(.system(size: 44, weight: .semibold))
                .tracking(-0.8)
                .foregroundStyle(Theme.text)
            Text("An earpiece that helps you larp.")
                .font(.system(size: 20))
                .foregroundStyle(Theme.text2)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "ear", title: "The perfect next line", detail: "It listens, then whispers what to say.")
                FeatureRow(symbol: "photo", title: "Proof on your phone", detail: "Asked for proof? It goes and finds a photo.")
                FeatureRow(symbol: "phone.fill", title: "A way out", detail: "One tap fakes a call so you can walk away.")
            }
            .padding(.top, 36)

            Spacer()

            VStack(spacing: 10) {
                Button("Get started") { mode = .signUp }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Button("I already have an account") { mode = .signIn }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(item: $mode) { mode in
            AuthView(startsOnSignUp: mode == .signUp)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text2)
            }
        }
    }
}

/// Email and password, for creating an account or signing back in.
private struct AuthView: View {
    private enum Field { case email, password }

    @Environment(AuthStore.self) private var auth
    @State private var isSignUp: Bool
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var message: String?
    @FocusState private var focus: Field?

    init(startsOnSignUp: Bool) {
        _isSignUp = State(initialValue: startsOnSignUp)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !working && trimmedEmail.contains("@") && !password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isSignUp ? "Create your account" : "Welcome back")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 6) {
                LabelText("Email")
                TextField("you@example.com", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
                    .modifier(AuthFieldStyle())
            }

            VStack(alignment: .leading, spacing: 6) {
                LabelText("Password")
                SecureField(isSignUp ? "At least 6 characters" : "Your password", text: $password)
                    .textContentType(isSignUp ? .newPassword : .password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
                    .modifier(AuthFieldStyle())
            }

            if let message {
                Text(message)
                    .font(Theme.body)
                    .foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submit) {
                if working {
                    ProgressView().tint(Theme.bg)
                } else {
                    Text(isSignUp ? "Create account" : "Sign in")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(!canSubmit)
            .padding(.top, 4)

            Button(isSignUp ? "I already have an account" : "Create an account") {
                isSignUp.toggle()
                message = nil
            }
            .font(Theme.body)
            .foregroundStyle(Theme.text2)
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(24)
        .background(Theme.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
        .onAppear { focus = .email }
    }

    private func submit() {
        guard canSubmit else { return }
        working = true
        message = nil
        focus = nil
        Task {
            defer { working = false }
            do {
                // Once signed in, RootView swaps to the app and this sheet goes with it.
                if isSignUp {
                    try await auth.signUp(email: trimmedEmail, password: password)
                } else {
                    try await auth.signIn(email: trimmedEmail, password: password)
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct AuthFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.body)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}
