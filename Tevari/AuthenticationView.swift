import SwiftUI

struct AuthenticationView: View {
    @StateObject private var auth = AuthenticationService()
    @State private var emailOrUsername = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var route: AuthenticationRoute?

    var body: some View {
        Group {
            switch route {
            case .resetPassword:
                PasswordResetView(prefilledEmail: emailOrUsername, auth: auth) { route = nil }
            case .createAccount:
                CreateAccountView(auth: auth) { route = nil }
            case nil:
                signInScreen
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tevariMidnight.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: Binding(get: { auth.user != nil }, set: { _ in })) {
            TevariHomeShell(auth: auth)
        }
    }

    private var signInScreen: some View {
        AuthenticationCanvas {
            VStack(alignment: .leading, spacing: 0) {
                BrandLockup()

                Text("Welcome back")
                    .font(.system(size: 28, weight: .medium, design: .default))
                    .foregroundStyle(.white)
                    .padding(.top, 28)

                Text("Sign in to continue your time with Tevari.")
                    .font(.system(size: 14, design: .default))
                    .foregroundStyle(.white.opacity(0.66))
                    .padding(.top, 6)

                VStack(spacing: 10) {
                    TevariTextField(title: "Email or username", text: $emailOrUsername, contentType: .username)
                    TevariPasswordField(title: "Password", text: $password, isVisible: $showsPassword, contentType: .password)
                }
                .padding(.top, 24)

                Button("Forgot password?") { route = .resetPassword }
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundStyle(Color.tevariGold)
                    .padding(.top, 12)

                Button(action: signIn) {
                    Text("Sign in")
                        .font(.system(size: 16, weight: .semibold, design: .default))
                }
                .buttonStyle(TevariPrimaryButtonStyle())
                .padding(.top, 22)

                TevariDivider()
                    .padding(.vertical, 18)

                Button(action: continueWithGoogle) {
                    HStack(spacing: 10) {
                        GoogleMark().frame(width: 19, height: 19)
                        Text("Continue with Google")
                            .font(.system(size: 15, weight: .semibold, design: .default))
                    }
                }
                .buttonStyle(TevariGlassButtonStyle())

                Button(action: continueAsGuest) {
                    Text("Continue as guest")
                        .font(.system(size: 14, weight: .semibold, design: .default))
                        .foregroundStyle(.white.opacity(0.76))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

                if let error = auth.errorMessage {
                    Text(error)
                        .font(.system(size: 13, design: .default))
                        .foregroundStyle(.red.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                }

                if auth.isWorking {
                    ProgressView()
                        .tint(Color.tevariGold)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }

                HStack(spacing: 5) {
                    Text("New to Tevari?")
                        .foregroundStyle(.white.opacity(0.57))
                    Button("Create an account") { route = .createAccount }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.tevariGold)
                }
                .font(.system(size: 13, design: .default))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
    }

    private func signIn() {
        Task { _ = await auth.signIn(email: emailOrUsername, password: password) }
    }

    private func continueWithGoogle() {
        Task { _ = await auth.signInWithGoogle() }
    }

    private func continueAsGuest() {
        Task { _ = await auth.continueAsGuest() }
    }
}

/// Applies a safe, narrow reading column on every phone and keeps every action reachable on short screens.
private struct AuthenticationCanvas<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.tevariMidnight.ignoresSafeArea()
            ambientLight

            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    content
                        .frame(maxWidth: 440, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 22)
                        .padding(.top, max(60, proxy.safeAreaInsets.top + 12))
                        .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 16))
                }
                .tevariScrollBounceBehavior()
            }
            .ignoresSafeArea()
        }
    }

    private var ambientLight: some View {
        GeometryReader { proxy in
            Circle()
                .fill(Color.tevariSage.opacity(0.13))
                .frame(width: proxy.size.width * 1.15)
                .blur(radius: 76)
                .offset(x: proxy.size.width * 0.36, y: -proxy.size.height * 0.39)
        }
        .ignoresSafeArea()
    }
}

private struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("TevariMark")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text("TEVARI")
                .font(.system(size: 14, weight: .medium, design: .default))
                .tracking(3)
                .foregroundStyle(.white)
        }
    }
}

private struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.left")
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .tevariGlass(in: Capsule())
        }
        .accessibilityLabel("Back")
    }
}

private struct DeviceSetupFlowView: View {
    @ObservedObject var auth: AuthenticationService
    @AppStorage("tevari.selectedDevicePath") private var selectedPath = ""
    @State private var glassesStep: GlassesStep = .intro
    @StateObject private var wearables = WearablesService()

    var body: some View {
        ZStack {
            Color.tevariMidnight.ignoresSafeArea()
            switch selectedPath {
            case "phone":
                TodayStarterView { selectedPath = "" }
            case "glasses":
                GlassesReadinessView(step: $glassesStep, wearables: wearables, continueOnPhone: { selectedPath = "phone" }, changeChoice: { selectedPath = "" })
            default:
                DeviceChoiceView(choosePhone: { selectedPath = "phone" }, chooseGlasses: { selectedPath = "glasses" })
            }
        }
    }
}

private struct DeviceChoiceView: View {
    let choosePhone: () -> Void
    let chooseGlasses: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup()
            Spacer()
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.tevariGold)
            Text("How would you like to begin?")
                .font(.system(size: 30, weight: .medium, design: .default))
                .foregroundStyle(.white)
                .padding(.top, 20)
            Text("Your iPhone is always your Tevari home. Connect glasses now, or continue on your phone and add them later.")
                .font(.system(size: 15, design: .default))
                .foregroundStyle(.white.opacity(0.66))
                .padding(.top, 7)
            Button(action: chooseGlasses) {
                Label("Connect Meta glasses", systemImage: "eyeglasses")
                    .font(.system(size: 16, weight: .semibold, design: .default))
            }
            .buttonStyle(TevariPrimaryButtonStyle())
            .padding(.top, 28)
            Button(action: choosePhone) {
                Label("Continue on iPhone", systemImage: "iphone")
                    .font(.system(size: 16, weight: .semibold, design: .default))
            }
            .buttonStyle(TevariGlassButtonStyle())
            .padding(.top, 12)
            Text("You can connect glasses later from Settings.")
                .font(.system(size: 13, design: .default))
                .foregroundStyle(.white.opacity(0.48))
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 76)
        .padding(.bottom, 34)
    }
}

private enum GlassesStep { case intro, approval }

private struct GlassesReadinessView: View {
    @Binding var step: GlassesStep
    @ObservedObject var wearables: WearablesService
    let continueOnPhone: () -> Void
    let changeChoice: () -> Void
    @State private var showsFaithLens = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("Back", action: changeChoice)
                .foregroundStyle(Color.tevariGold)
                .font(.system(size: 14, weight: .semibold, design: .default))
            Spacer().frame(height: 28)
            Image(systemName: "eyeglasses")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.tevariGold)
            Text(wearables.isExperienceActive ? "Your glasses are connected" : "Connect your Meta glasses")
                .font(.system(size: 29, weight: .medium, design: .default))
                .foregroundStyle(.white)
                .padding(.top, 20)
            Text(step == .intro ? "Tevari will ask Meta AI to approve the connection. It never starts the camera or microphone automatically." : "When your glasses are available, start a display-only Tevari session. Camera and microphone stay off.")
                .font(.system(size: 15, design: .default))
                .foregroundStyle(.white.opacity(0.66))
                .padding(.top, 7)
            readinessRow("Meta AI connection", complete: wearables.isRegistered, detail: wearables.registrationStatus)
                .padding(.top, 26)
            readinessRow("Available glasses", complete: !wearables.availableDeviceNames.isEmpty, detail: wearables.availableDeviceNames.isEmpty ? "Open and wear your glasses" : wearables.availableDeviceNames.joined(separator: ", "))
            readinessRow("Glasses display", complete: wearables.isExperienceActive, detail: wearables.hasDisplayCapableGlasses ? wearables.displayStatus : "Waiting for display-capable glasses")
            readinessRow("Camera and microphone", complete: false, detail: "Off — requested only when you use them")
            Button(primaryButtonTitle) {
                switch step {
                case .intro:
                    wearables.startRegistration()
                    step = .approval
                case .approval:
                    if wearables.isExperienceActive {
                        wearables.stopGlassesExperience()
                    } else if !wearables.isRegistered {
                        wearables.startRegistration()
                    } else {
                        wearables.startGlassesExperience()
                    }
                }
            }
            .buttonStyle(TevariPrimaryButtonStyle())
            .padding(.top, 28)
            if step == .approval {
                Text("Session status: \(wearables.sessionStatus)")
                    .font(.system(size: 13, design: .default))
                    .foregroundStyle(.white.opacity(0.66))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            if let error = wearables.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            if wearables.isExperienceActive {
                Button {
                    showsFaithLens = true
                } label: {
                    Label("Open Faith Lens", systemImage: "camera.viewfinder")
                }
                .buttonStyle(TevariGlassButtonStyle())
                .padding(.top, 12)
            }
            if wearables.requiresGlassesAppUpdate {
                Button("Update app on glasses") {
                    wearables.openGlassesAppUpdate()
                }
                .buttonStyle(TevariGlassButtonStyle())
                .padding(.top, 12)
            }
            Button("Continue on iPhone", action: continueOnPhone)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.top, 15)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 62)
        .padding(.bottom, 34)
        .fullScreenCover(isPresented: $showsFaithLens) {
            FaithLensControlView(wearables: wearables) {
                showsFaithLens = false
            }
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .intro: "Connect in Meta AI"
        case .approval:
            wearables.isExperienceActive ? "End glasses session" : wearables.isRegistered ? "Start glasses session" : "Finish Meta AI connection"
        }
    }

    private func readinessRow(_ title: String, complete: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(complete ? Color.tevariSage : .white.opacity(0.38))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium, design: .default))
                if let detail { Text(detail).font(.system(size: 12, design: .default)).foregroundStyle(.white.opacity(0.5)) }
            }
            .foregroundStyle(.white)
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

/// The phone is the private control surface for Faith Lens: it shows the
/// locally streamed preview, live question, and the explicit capture action.
/// The glasses stay uncluttered and show only the final reflection and verse.
private struct FaithLensControlView: View {
    @ObservedObject var wearables: WearablesService
    let onDone: () -> Void
    @State private var typedQuestion = ""

    private var question: String {
        let typed = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? wearables.faithLensQuestion : typed
    }

    var body: some View {
        AuthenticationCanvas {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BackButton(action: endFaithLens)
                    Spacer()
                    Text("FAITH LENS")
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .tracking(2)
                        .foregroundStyle(Color.tevariGold)
                }

                Text("See this moment through faith")
                    .font(.system(size: 28, weight: .medium, design: .default))
                    .foregroundStyle(.white)
                    .padding(.top, 26)
                Text("Point your glasses, ask what is on your heart, then capture one moment for Tevari to reflect on.")
                    .font(.system(size: 14, design: .default))
                    .foregroundStyle(.white.opacity(0.66))
                    .padding(.top, 7)

                preview
                    .padding(.top, 22)

                Text(wearables.faithLensStatus)
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(wearables.faithLensStatus.contains("Could not") ? .red : Color.tevariSage)
                    .padding(.top, 10)

                if wearables.latestFaithLensFrame == nil {
                    Button("Start camera") { wearables.startFaithLensCamera() }
                        .buttonStyle(TevariPrimaryButtonStyle())
                        .padding(.top, 16)
                } else {
                    questionControls
                        .padding(.top, 18)
                }

                if let response = wearables.faithLensResponse {
                    responseCard(response)
                        .padding(.top, 22)
                }

                if let error = wearables.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 14)
                }

                Text("Your preview remains on this phone. Tevari sends only the frame you capture and the question you choose. Nothing is saved unless you choose Save.")
                    .font(.system(size: 12, design: .default))
                    .foregroundStyle(.white.opacity(0.48))
                    .padding(.top, 22)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { wearables.openFaithLens() }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.35))
            if let image = wearables.latestFaithLensFrame {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.tevariGold)
                    Text("Camera is off")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .frame(height: 238)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .tevariGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var questionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your question")
                .font(.system(size: 16, weight: .medium, design: .default))
                .foregroundStyle(.white)
            Text(wearables.faithLensQuestion.isEmpty ? "Tap Ask by voice, then speak naturally." : wearables.faithLensQuestion)
                .font(.system(size: 15, design: .default))
                .foregroundStyle(.white.opacity(wearables.faithLensQuestion.isEmpty ? 0.48 : 0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Or type your question", text: $typedQuestion, axis: .vertical)
                .lineLimit(2...4)
                .padding(14)
                .tevariGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
            HStack(spacing: 10) {
                Button(wearables.faithLensStatus == "Listening for your question" ? "Stop listening" : "Ask by voice") {
                    if wearables.faithLensStatus == "Listening for your question" {
                        wearables.stopFaithLensListening()
                    } else {
                        typedQuestion = ""
                        wearables.startFaithLensListening()
                    }
                }
                .buttonStyle(TevariGlassButtonStyle())

                Button("Capture") {
                    wearables.stopFaithLensListening()
                    wearables.captureFaithLens(question: question)
                }
                .buttonStyle(TevariPrimaryButtonStyle())
                .disabled(question.isEmpty || wearables.faithLensStatus == "Capturing this moment" || wearables.faithLensStatus == "Reflecting on this moment")
                .opacity(question.isEmpty ? 0.5 : 1)
            }
        }
    }

    private func responseCard(_ response: TevariFaithLensResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reflection")
                .font(.system(size: 16, weight: .medium, design: .default))
                .foregroundStyle(Color.tevariGold)
            Text(response.response)
                .font(.system(size: 15, design: .default))
                .foregroundStyle(.white)
            Text("Scripture")
                .font(.system(size: 16, weight: .medium, design: .default))
                .foregroundStyle(Color.tevariGold)
                .padding(.top, 4)
            Text(response.scripture.reference)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(.white)
            Text(response.scripture.content)
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(.white.opacity(0.88))
            Text("Bible text via YouVersion • \(response.scripture.bible.title) (\(response.scripture.bible.abbreviation))")
                .font(.system(size: 11, design: .default))
                .foregroundStyle(.white.opacity(0.48))
            if let prayer = response.prayer {
                Text("Prayer")
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .foregroundStyle(Color.tevariGold)
                    .padding(.top, 4)
                Text(prayer)
                    .font(.system(size: 14, design: .default))
                    .foregroundStyle(.white.opacity(0.88))
            }
            Button("Hear response") { wearables.speakFaithLensResponse() }
                .buttonStyle(TevariGlassButtonStyle())
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tevariGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func endFaithLens() {
        wearables.stopFaithLensCamera()
        wearables.returnToGlassesHome()
        onDone()
    }
}

private struct TodayStarterView: View {
    let changeDevice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BrandLockup()
                Spacer()
                Button(action: changeDevice) { Image(systemName: "eyeglasses") }
                    .foregroundStyle(Color.tevariGold)
            }
            Text("Today")
                .font(.system(size: 34, weight: .medium, design: .default))
                .foregroundStyle(.white)
                .padding(.top, 34)
            Text("A quieter place to begin.")
                .font(.system(size: 15, design: .default))
                .foregroundStyle(.white.opacity(0.66))
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Tevari space is ready")
                    .font(.system(size: 19, weight: .medium, design: .default))
                Text("Next, we’ll set your Scripture and reflection preferences before beginning your first moment.")
                    .font(.system(size: 14, design: .default))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tevariGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.top, 30)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 76)
        .padding(.bottom, 34)
    }
}

private enum AuthenticationRoute: Hashable, Identifiable {
    case resetPassword
    case createAccount
    var id: Self { self }
}

private struct TevariTextField: View {
    let title: String
    @Binding var text: String
    let contentType: UITextContentType

    var body: some View {
        TextField(title, text: $text)
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 16)
            .frame(height: 48)
            .tevariGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TevariPasswordField: View {
    let title: String
    @Binding var text: String
    @Binding var isVisible: Bool
    let contentType: UITextContentType

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isVisible { TextField(title, text: $text) }
                else { SecureField(title, text: $text) }
            }
            .textContentType(contentType)

            Button { isVisible.toggle() } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(isVisible ? "Hide password" : "Show password")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .tevariGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TevariDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(.white.opacity(0.13)).frame(height: 1)
            Text("or")
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(.white.opacity(0.48))
            Rectangle().fill(.white.opacity(0.13)).frame(height: 1)
        }
    }
}

private struct PasswordResetView: View {
    @ObservedObject var auth: AuthenticationService
    let onBack: () -> Void
    @State private var email: String
    @State private var didRequestReset = false

    init(prefilledEmail: String, auth: AuthenticationService, onBack: @escaping () -> Void) {
        _email = State(initialValue: prefilledEmail)
        self.auth = auth
        self.onBack = onBack
    }

    var body: some View {
        AuthenticationCanvas {
            VStack(alignment: .leading, spacing: 0) {
                BackButton(action: onBack)
                BrandLockup()
                    .padding(.top, 24)
                Image(systemName: "key.horizontal")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.tevariGold)
                    .padding(.top, 30)
                Text(didRequestReset ? "Check your inbox" : "Reset your password")
                    .font(.system(size: 28, weight: .medium, design: .default))
                    .foregroundStyle(.white)
                    .padding(.top, 18)
                Text(didRequestReset ? "If an account matches that email, we’ve sent a reset link." : "Enter your email and we’ll send a secure reset link.")
                    .font(.system(size: 14, design: .default))
                    .foregroundStyle(.white.opacity(0.66))
                    .padding(.top, 6)
                if !didRequestReset {
                    TevariTextField(title: "Email address", text: $email, contentType: .emailAddress)
                        .padding(.top, 24)
                    Button("Send reset link") {
                        Task { if await auth.sendPasswordReset(email: email) { didRequestReset = true } }
                    }
                    .buttonStyle(TevariPrimaryButtonStyle())
                    .padding(.top, 16)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct CreateAccountView: View {
    @ObservedObject var auth: AuthenticationService
    let onBack: () -> Void
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var acceptedTerms = false

    var body: some View {
        AuthenticationCanvas {
            VStack(alignment: .leading, spacing: 0) {
                BackButton(action: onBack)
                BrandLockup()
                    .padding(.top, 24)
                Text("Create your space")
                    .font(.system(size: 28, weight: .medium, design: .default))
                    .foregroundStyle(.white)
                    .padding(.top, 28)
                Text("Save the moments, prayers, and Scripture that matter to you.")
                    .font(.system(size: 14, design: .default))
                    .foregroundStyle(.white.opacity(0.66))
                    .padding(.top, 6)

                VStack(spacing: 10) {
                    TevariTextField(title: "Your name", text: $name, contentType: .name)
                    TevariTextField(title: "Email address", text: $email, contentType: .emailAddress)
                    TevariPasswordField(title: "Create a password", text: $password, isVisible: $showsPassword, contentType: .newPassword)
                }
                .padding(.top, 24)

                Button { acceptedTerms.toggle() } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: acceptedTerms ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19))
                            .foregroundStyle(acceptedTerms ? Color.tevariGold : .white.opacity(0.45))
                        Text("I agree to Tevari’s Terms and Privacy Policy.")
                            .font(.system(size: 13, design: .default))
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.top, 18)

                Button("Create account") {
                    Task { _ = await auth.createAccount(name: name, email: email, password: password) }
                }
                .buttonStyle(TevariPrimaryButtonStyle())
                .disabled(!acceptedTerms || email.isEmpty || password.isEmpty)
                .opacity(acceptedTerms && !email.isEmpty && !password.isEmpty ? 1 : 0.5)
                .padding(.top, 20)

                if let error = auth.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red.opacity(0.9)).padding(.top, 10)
                }
                if auth.isWorking { ProgressView().tint(Color.tevariGold).padding(.top, 10) }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct TevariPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(Color.tevariMidnight)
            .background(Color.tevariGold, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct TevariGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(.white)
            .tevariGlass(in: Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct GoogleMark: View {
    var body: some View {
        Text("G")
            .font(.system(size: 19, weight: .bold, design: .default))
            .foregroundStyle(LinearGradient(colors: [.blue, .red, .yellow, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

#Preview { AuthenticationView() }
