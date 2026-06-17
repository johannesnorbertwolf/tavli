import SwiftUI

private typealias SColor = SwiftUI.Color

/// Password gate for the Weltsensation app. A deliberately insecure deterrent:
/// the password is hardcoded (`Weltsensation.password`) and only meant to keep
/// the family out of the app before the tournament. Passed once, it's remembered
/// (`WeltsensationKey.unlocked`); "App sperren" in Setup brings this screen back.
struct LockView: View {
    @AppStorage(WeltsensationKey.unlocked) private var unlocked = false

    @State private var entry = ""
    @State private var wrong = false
    @State private var shake: CGFloat = 0

    var body: some View {
        ZStack {
            Weltsensation.page.ignoresSafeArea()

            VStack(spacing: 24) {
                Text(Weltsensation.appTitle)
                    .font(ChromeType.wordmark)
                    .foregroundStyle(CaramelPalette.frameText)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                Text("Bitte Passwort eingeben")
                    .font(ChromeType.body)
                    .foregroundStyle(ChromeKit.inkSecondary)

                VStack(spacing: 14) {
                    SecureField("Passwort", text: $entry)
                        .font(ChromeType.body)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(SColor.white.opacity(0.6))
                        .cornerRadius(ChromeKit.buttonRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChromeKit.buttonRadius)
                                .stroke(wrong ? ChromeTheme.surrenderTint : ChromeTheme.ink.opacity(0.12),
                                        lineWidth: 1)
                        )
                        .onSubmit(attempt)
                        .onChange(of: entry) { _, _ in wrong = false }

                    if wrong {
                        Text("Falsches Passwort")
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeTheme.surrenderTint)
                    }

                    Button("Entsperren", action: attempt)
                        .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                }
                .chromeCard(padding: 22)
                .frame(maxWidth: 380)
                .offset(x: shake)
            }
            .padding(40)
        }
    }

    private func attempt() {
        if entry == Weltsensation.password {
            unlocked = true
        } else {
            entry = ""
            withAnimation(.default) { wrong = true }
            shakeOnce()
        }
    }

    /// A short left-right shake to signal a rejected password.
    private func shakeOnce() {
        let offsets: [CGFloat] = [-12, 10, -7, 4, 0]
        for (i, x) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                withAnimation(.easeInOut(duration: 0.05)) { shake = x }
            }
        }
    }
}

#Preview {
    LockView()
}
