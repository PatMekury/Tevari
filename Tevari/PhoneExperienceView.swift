import AVFoundation
import Combine
import FirebaseAuth
import MediaPlayer
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Phone routing

@MainActor
final class TevariAppRouter: ObservableObject {
    static let shared = TevariAppRouter()
    @Published var requestedModule: TevariPhoneModule?

    func open(_ module: TevariPhoneModule) {
        requestedModule = module
    }
}

enum TevariPhoneModule: String, CaseIterable, Identifiable {
    case prayer, faithLens, story, parallel

    var id: String { rawValue }
    var title: String {
        switch self {
        case .prayer: "Prayer"
        case .faithLens: "Faith Lens"
        case .story: "Story"
        case .parallel: "Parallel"
        }
    }
    var subtitle: String {
        switch self {
        case .prayer: "Put words to this moment."
        case .faithLens: "See a moment through Scripture."
        case .story: "Enter a Bible story."
        case .parallel: "Find the scene that meets your life."
        }
    }
    var symbol: String {
        switch self {
        case .prayer: "hands.sparkles"
        case .faithLens: "viewfinder.circle"
        case .story: "book.closed"
        case .parallel: "arrow.triangle.branch"
        }
    }
}

// MARK: - Companion home

struct TevariHomeShell: View {
    @ObservedObject var auth: AuthenticationService
    @StateObject private var wearables = WearablesService()
    @ObservedObject private var router = TevariAppRouter.shared
    @AppStorage("tevari.home.mode") private var selectedMode = "phone"
    @State private var showsSettings = false

    var body: some View {
        ZStack {
            TevariSanctuaryBackground()
            VStack(spacing: 0) {
                homeHeader
                modePicker
                    .padding(.top, 22)
                Group {
                    if selectedMode == "glasses" {
                        GlassesCompanionView(wearables: wearables) { selectedMode = "phone" }
                    } else {
                        PhoneHomeView(wearables: wearables) { router.open($0) }
                    }
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)), removal: .opacity))
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $router.requestedModule) { module in
            PhoneModuleView(module: module, wearables: wearables)
        }
        .sheet(isPresented: $showsSettings) {
            TevariSettingsView(auth: auth, wearables: wearables)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: router.requestedModule) { module in
            guard module != nil else { return }
            selectedMode = "phone"
        }
        .onOpenURL { url in
            guard url.scheme == "tevari" else { return }
            let destination = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let module = TevariPhoneModule(rawValue: destination) { router.open(module) }
        }
    }

    private var homeHeader: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Image("TevariMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TEVARI")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(4)
                        .foregroundStyle(Color.tevariGold)
                    Text("A faithful way through the present.")
                        .font(.system(size: 17, weight: .medium, design: .serif))
                        .foregroundStyle(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button { showsSettings = true } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.13), lineWidth: 1))
            }
            .accessibilityLabel("Account and settings")
        }
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton("Phone", symbol: "iphone", value: "phone")
            modeButton("Glasses", symbol: "eyeglasses", value: "glasses")
        }
        .padding(4)
        .background(.black.opacity(0.24), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func modeButton(_ title: String, symbol: String, value: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { selectedMode = value }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selectedMode == value ? Color.tevariMidnight : .white.opacity(0.62))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(selectedMode == value ? Color.tevariGold : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PhoneHomeView: View {
    @ObservedObject var wearables: WearablesService
    let open: (TevariPhoneModule) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                TimelineView(.periodic(from: .now, by: 1.2)) { context in
                    TodayField(date: context.date, tradition: wearables.tradition)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(TevariPhoneModule.allCases) { module in
                        Button { open(module) } label: { ModuleTile(module: module) }
                            .buttonStyle(TevariPressStyle())
                    }
                }
                SiriInvocationCard()
                Text("Tevari responds with grounded Scripture from YouVersion. Your faith background shapes the language and interpretation.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.48))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 26)
            }
            .padding(.top, 24)
        }
        .tevariScrollBounceBehavior()
    }
}

private struct TodayField: View {
    let date: Date
    let tradition: WearablesService.Tradition

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.tevariGold)
                Spacer()
                Text(tradition.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Text("Where is your attention\nneeded today?")
                .font(.system(size: 31, weight: .medium, design: .serif))
                .foregroundStyle(.white)
                .lineSpacing(2)
            Text("Start with the experience that fits this exact moment.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.66))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.tevariGold.opacity(0.13))
                .overlay(alignment: .topTrailing) {
                    ArcHalo()
                        .stroke(Color.tevariGold.opacity(0.34), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 7]))
                        .frame(width: 150, height: 150)
                        .rotationEffect(.degrees(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 18) * 20))
                        .offset(x: 35, y: -56)
                }
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }
}

private struct ModuleTile: View {
    let module: TevariPhoneModule
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: module.symbol)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Color.tevariGold)
                .frame(width: 46, height: 46)
                .background(Color.tevariGold.opacity(0.13), in: Circle())
            Spacer(minLength: 7)
            Text(module.title)
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
            Text(module.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: 174, alignment: .leading)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct GlassesCompanionView: View {
    @ObservedObject var wearables: WearablesService
    let continueOnPhone: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(wearables.isExperienceActive ? "Glasses are live" : "Your glasses companion", systemImage: "eyeglasses")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.tevariGold)
                    Text(wearables.isExperienceActive ? "Choose any experience below. It will appear in your glasses immediately." : "Connect once, then move between phone and glasses without losing your place.")
                        .font(.system(size: 18, weight: .regular, design: .serif))
                        .foregroundStyle(.white)
                }
                .padding(21)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                connectionRow("Meta AI", detail: wearables.registrationStatus, complete: wearables.isRegistered)
                connectionRow("Display", detail: wearables.displayStatus, complete: wearables.isExperienceActive)

                Button(wearables.isExperienceActive ? "End glasses session" : wearables.isRegistered ? "Start glasses session" : "Connect in Meta AI") {
                    if wearables.isExperienceActive { wearables.stopGlassesExperience() }
                    else if wearables.isRegistered { wearables.startGlassesExperience() }
                    else { wearables.startRegistration() }
                }
                .buttonStyle(PhonePrimaryButtonStyle())

                if wearables.isExperienceActive {
                    HStack(spacing: 13) {
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Color.tevariGold)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connect glasses microphone")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Tap the route icon and choose your glasses before starting a spoken experience.")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        Spacer(minLength: 8)
                        GlassesAudioRoutePicker()
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("Choose glasses audio route")
                    }
                    .padding(15)
                    .background(Color.tevariGold.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.tevariGold.opacity(0.25), lineWidth: 1))
                    .onAppear { wearables.prepareGlassesAudioRoute() }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Send to glasses")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.70))
                        ForEach(TevariPhoneModule.allCases) { module in
                            Button {
                                switch module {
                                case .prayer: wearables.openPrayerExperience()
                                case .faithLens: wearables.openFaithLens()
                                case .story: wearables.openStory()
                                case .parallel: wearables.openParallel()
                                }
                            } label: {
                                HStack { Image(systemName: module.symbol); Text(module.title); Spacer(); Image(systemName: "arrow.up.right") }
                            }
                            .buttonStyle(PhoneSecondaryButtonStyle())
                        }
                    }
                }
                if let error = wearables.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red.opacity(0.9))
                }
                Button("Use phone experiences") { continueOnPhone() }
                    .buttonStyle(PhoneSecondaryButtonStyle())
                    .padding(.bottom, 28)
            }
            .padding(.top, 24)
        }
    }

    private func connectionRow(_ title: String, detail: String, complete: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(complete ? Color.tevariSage : .white.opacity(0.36))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.white).fontWeight(.medium)
                Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
        }
        .padding(16)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Apple's route picker is the supported way for the wearer to choose a
/// paired Bluetooth HFP device. Once selected, iOS routes its microphone and
/// output together for the active `.playAndRecord` session.
private struct GlassesAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let routePicker = MPVolumeView(frame: .zero)
        routePicker.showsVolumeSlider = false
        routePicker.showsRouteButton = true
        routePicker.tintColor = UIColor(Color.tevariGold)
        routePicker.backgroundColor = .clear
        return routePicker
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Phone modules

private struct PhoneModuleView: View {
    let module: TevariPhoneModule
    @ObservedObject var wearables: WearablesService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch module {
                case .prayer: PhonePrayerView(wearables: wearables)
                case .faithLens: PhoneFaithLensView(wearables: wearables)
                case .story: PhoneStoryView(wearables: wearables)
                case .parallel: PhoneParallelView(wearables: wearables)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.tevariGold)
                }
            }
            .toolbarBackground(Color.tevariMidnight, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

private struct PhonePrayerView: View {
    @ObservedObject var wearables: WearablesService
    @State private var words = ""
    @State private var result: TevariPrayerPrompt?
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        ModuleCanvas(module: .prayer, title: "Pray from where you are", isWaiting: isLoading) {
            if let result { PrayerResultCard(result: result) }
            if let error { ErrorLine(message: error) }
        } composer: {
            PromptComposer(prompt: $words, placeholder: "What would you like to bring into prayer?", actionTitle: "Create a prayer", isLoading: isLoading) { submit() }
        }
    }

    private func submit() {
        let prompt = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isLoading = true; error = nil
        Task {
            do { let response = try await TevariAPI.prayerContinuation(history: [.spoken(prompt)], tradition: wearables.tradition.rawValue); await MainActor.run { result = response; words = ""; isLoading = false } }
            catch { await MainActor.run { self.error = error.localizedDescription; isLoading = false } }
        }
    }
}

private struct PhoneStoryView: View {
    @ObservedObject var wearables: WearablesService
    @State private var prompt = ""
    @State private var result: TevariStoryScene?
    @State private var error: String?
    @State private var isLoading = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPreparingNarration = false
    @State private var isNarrating = false

    var body: some View {
        ModuleCanvas(module: .story, title: "Enter the story", isWaiting: isLoading || isPreparingNarration, waitingTitle: isPreparingNarration ? "Preparing narration" : "Finding the story") {
            if let result {
                ResultCard(title: result.title, eyebrow: result.scripture.reference) {
                    Text(result.guide).font(.subheadline).foregroundStyle(.white.opacity(0.68))
                    Text(result.narration).font(.system(size: 17, design: .serif)).foregroundStyle(.white)
                    ScriptureCard(scripture: result.scripture)
                    Button(isPreparingNarration ? "Preparing narration…" : isNarrating ? "Narrating" : "Hear narration") { narrate(result.narration) }
                        .buttonStyle(PhoneSecondaryButtonStyle()).disabled(isPreparingNarration || isNarrating)
                    if isNarrating { NarrationPlayingIndicator() }
                    Button("Continue story") { continueStory(from: result) }
                        .buttonStyle(PhoneSecondaryButtonStyle()).disabled(isLoading || isPreparingNarration)
                }
            }
            if let error { ErrorLine(message: error) }
        } composer: {
            PromptComposer(prompt: $prompt, placeholder: "Tell me the Bible story you want to hear", actionTitle: "Find the story", isLoading: isLoading) { submit() }
        }
    }

    private func submit() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        isLoading = true; error = nil
        Task { do { let scene = try await TevariAPI.storyScene(prompt: text, tradition: wearables.tradition.rawValue); await MainActor.run { result = scene; prompt = ""; isLoading = false } } catch { await MainActor.run { self.error = error.localizedDescription; isLoading = false } } }
    }
    private func narrate(_ narration: String) {
        isPreparingNarration = true
        Task {
            do {
                let data = try await TevariAPI.storyNarration(narration)
                let session = AVAudioSession.sharedInstance()
                // This is the same conservative spoken-playback setup used by
                // the working glasses narration path. A2DP/default-speaker
                // options are not valid for every active route and can throw
                // OSStatus -50 before any audio is played.
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
                try session.setActive(true)
                let player = try AVAudioPlayer(data: data)
                player.prepareToPlay()
                guard player.play() else { throw TevariAPIError.invalidResponse }
                await MainActor.run { audioPlayer = player; isPreparingNarration = false; isNarrating = true }
                let duration = player.duration
                try? await Task.sleep(for: .seconds(duration))
                await MainActor.run { if audioPlayer === player { isNarrating = false } }
            } catch let caughtError {
                await MainActor.run { self.error = caughtError.localizedDescription; isPreparingNarration = false; isNarrating = false }
            }
        }
    }

    private func continueStory(from scene: TevariStoryScene) {
        isLoading = true; error = nil
        Task {
            do {
                let next = try await TevariAPI.storyScene(
                    prompt: "Continue this Bible story.",
                    tradition: wearables.tradition.rawValue,
                    continuationPassageID: scene.scripture.id
                )
                await MainActor.run { result = next; isLoading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; isLoading = false }
            }
        }
    }
}

private struct PhoneFaithLensView: View {
    @ObservedObject var wearables: WearablesService
    @State private var prompt = ""
    @State private var imageData: Data?
    @State private var showsPhotoLibrary = false
    @State private var showsCamera = false
    @State private var result: TevariFaithLensResponse?
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        ModuleCanvas(module: .faithLens, title: "Look again", isWaiting: isLoading, waitingTitle: "Reflecting on this moment") {
            FaithLensStage(imageData: imageData)
            if let result { FaithLensResultCard(result: result) }
            if let error { ErrorLine(message: error) }
        } composer: {
            PromptComposer(
                prompt: $prompt,
                placeholder: imageData == nil ? "Add a photo, then ask about this moment" : "Ask about this moment",
                actionTitle: "Reflect on this moment",
                isLoading: isLoading,
                attachment: ComposerAttachment(imageData: $imageData, showsPhotoLibrary: $showsPhotoLibrary, showsCamera: $showsCamera),
                canSubmit: imageData != nil
            ) { submit() }
        }
        .sheet(isPresented: $showsPhotoLibrary) { PhonePhotoLibraryPicker(imageData: $imageData) }
        .sheet(isPresented: $showsCamera) { PhoneCameraPicker(imageData: $imageData) }
    }
    private func submit() {
        guard let imageData else { return }; let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines); guard !question.isEmpty else { return }
        isLoading = true; error = nil
        Task { do { let response = try await TevariAPI.faithLens(imageData: imageData, question: question, tradition: wearables.tradition.rawValue); await MainActor.run { result = response; prompt = ""; self.imageData = nil; isLoading = false } } catch { await MainActor.run { self.error = error.localizedDescription; isLoading = false } } }
    }
}

private struct PhoneParallelView: View {
    @ObservedObject var wearables: WearablesService
    @State private var prompt = ""
    @State private var imageData: Data?
    @State private var showsPhotoLibrary = false
    @State private var showsCamera = false
    @State private var result: TevariParallel?
    @State private var error: String?
    @State private var isLoading = false
    var body: some View {
        ModuleCanvas(module: .parallel, title: "Find the parallel", isWaiting: isLoading, waitingTitle: "Finding parallels in Scripture") {
            if let result {
                ResultCard(title: "Similar in Scripture", eyebrow: "A grounded parallel") {
                    ScriptureCard(scripture: result.scripture)
                    ForEach(Array(result.supporting.enumerated()), id: \.offset) { _, passage in ScriptureCard(scripture: passage) }
                }
            }
            if let error { ErrorLine(message: error) }
        } composer: {
            PromptComposer(
                prompt: $prompt,
                placeholder: "Describe the real moment you are living",
                actionTitle: "Find Scripture",
                isLoading: isLoading,
                attachment: ComposerAttachment(imageData: $imageData, showsPhotoLibrary: $showsPhotoLibrary, showsCamera: $showsCamera)
            ) { submit() }
        }
        .sheet(isPresented: $showsPhotoLibrary) { PhonePhotoLibraryPicker(imageData: $imageData) }
        .sheet(isPresented: $showsCamera) { PhoneCameraPicker(imageData: $imageData) }
    }
    private func submit() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        isLoading = true; error = nil
        Task { do { let response = try await TevariAPI.parallel(prompt: text, imageData: imageData, tradition: wearables.tradition.rawValue); await MainActor.run { result = response; prompt = ""; self.imageData = nil; isLoading = false } } catch { await MainActor.run { self.error = error.localizedDescription; isLoading = false } } }
    }
}

// MARK: - Shared module UI

private struct ModuleCanvas<Content: View, Composer: View>: View {
    let module: TevariPhoneModule
    let title: String
    let isWaiting: Bool
    let waitingTitle: String
    let content: Content
    let composer: Composer

    init(
        module: TevariPhoneModule,
        title: String,
        isWaiting: Bool,
        waitingTitle: String = "Preparing your response",
        @ViewBuilder content: () -> Content,
        @ViewBuilder composer: () -> Composer
    ) {
        self.module = module
        self.title = title
        self.isWaiting = isWaiting
        self.waitingTitle = waitingTitle
        self.content = content()
        self.composer = composer()
    }

    var body: some View {
        ZStack {
            TevariSanctuaryBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: module.symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(Color.tevariGold)
                    Text(module.title.uppercased()).font(.system(size: 12, weight: .bold)).tracking(2.5).foregroundStyle(Color.tevariGold)
                    Text(title).font(.system(size: 34, weight: .medium, design: .serif)).foregroundStyle(.white)
                    Text(module.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.64)).padding(.bottom, 5)
                    content
                    Spacer(minLength: 112)
                }
                .padding(.horizontal, 22)
                .padding(.top, 78)
                .padding(.bottom, 22)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { hidePhoneKeyboard() })
        }
        .overlay {
            if isWaiting {
                ResponseWaitingOverlay(module: module, title: waitingTitle)
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(Color.tevariMidnight.opacity(0.92))
        }
    }
}

private struct ResponseWaitingOverlay: View {
    let module: TevariPhoneModule
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expands = false

    var body: some View {
        ZStack {
            Color.tevariMidnight.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 17) {
                ZStack {
                    Circle().stroke(Color.tevariGold.opacity(0.22), lineWidth: 1).frame(width: 86, height: 86).scaleEffect(expands ? 1.18 : 0.84).opacity(expands ? 0.25 : 0.9)
                    Circle().trim(from: 0.08, to: 0.72).stroke(Color.tevariGold, style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 58, height: 58).rotationEffect(.degrees(expands ? 360 : 0))
                    Image(systemName: module.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                }
                Text(title).font(.system(size: 20, weight: .medium, design: .serif)).foregroundStyle(.white)
                Text("Grounding this in Scripture…").font(.footnote).foregroundStyle(.white.opacity(0.64))
            }
            .padding(30)
            .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) { expands = true }
        }
    }
}

private struct ComposerAttachment {
    let imageData: Binding<Data?>
    let showsPhotoLibrary: Binding<Bool>
    let showsCamera: Binding<Bool>
}

private struct PromptComposer: View {
    @Binding var prompt: String
    let placeholder: String
    let actionTitle: String
    let isLoading: Bool
    var attachment: ComposerAttachment?
    var canSubmit = true
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var attachmentMenuIsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let data = attachment?.imageData.wrappedValue, let image = UIImage(data: data) {
                HStack(spacing: 9) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Text("Moment attached").font(.footnote).foregroundStyle(.white.opacity(0.70))
                    Spacer()
                    Button { attachment?.imageData.wrappedValue = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.58)) }
                        .accessibilityLabel("Remove attached moment")
                }
                .padding(.horizontal, 8)
            }
            HStack(alignment: isFocused ? .bottom : .center, spacing: 10) {
                if attachment != nil {
                    Button { attachmentMenuIsOpen = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.tevariGold)
                            .frame(width: 32, height: 32)
                            .background(Color.tevariGold.opacity(0.13), in: Circle())
                    }
                    .accessibilityLabel("Add a photo")
                }
                TextField(placeholder, text: $prompt, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(isFocused ? 3...7 : 1...1)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .submitLabel(.send)
                    .onSubmit { submitIfPossible() }
                Button(action: submitIfPossible) {
                    Image(systemName: isLoading ? "ellipsis" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canSubmit && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading ? Color.tevariMidnight : .white.opacity(0.36))
                        .frame(width: 36, height: 36)
                        .background(canSubmit && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading ? Color.tevariGold : .white.opacity(0.10), in: Circle())
                }
                .disabled(!canSubmit || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                .accessibilityLabel(isLoading ? "Preparing" : actionTitle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, isFocused ? 12 : 8)
            .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(isFocused ? Color.tevariGold.opacity(0.5) : .white.opacity(0.16), lineWidth: 1))
        }
        .confirmationDialog("Add a moment", isPresented: $attachmentMenuIsOpen, titleVisibility: .visible) {
            if let attachment {
                Button("Photo Library") { attachment.showsPhotoLibrary.wrappedValue = true }
                Button("Camera") { attachment.showsCamera.wrappedValue = true }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func submitIfPossible() {
        guard canSubmit, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isLoading else { return }
        isFocused = false
        hidePhoneKeyboard()
        action()
    }
}

private struct PrayerResultCard: View {
    let result: TevariPrayerPrompt
    var body: some View {
        ResultCard(title: "A prayer to begin", eyebrow: result.scripture.reference) {
            Text(result.prompt).font(.system(size: 18, design: .serif)).foregroundStyle(.white)
            ScriptureCard(scripture: result.scripture)
        }
    }
}

private struct FaithLensResultCard: View {
    let result: TevariFaithLensResponse
    var body: some View {
        ResultCard(title: result.response.isEmpty ? "Scripture for this moment" : "Reflection", eyebrow: result.scripture.reference) {
            if !result.response.isEmpty {
                Text(result.response).font(.system(size: 17, design: .serif)).foregroundStyle(.white)
            }
            if let prayer = result.prayer { Text("Prayer\n\(prayer)").font(.subheadline).foregroundStyle(.white.opacity(0.72)) }
            ScriptureCard(scripture: result.scripture)
        }
    }
}

private struct NarrationPlayingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animates = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform").foregroundStyle(Color.tevariGold)
            Text("Narrating on iPhone").font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.72))
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(Color.tevariGold).frame(width: 3, height: animates ? CGFloat(8 + index * 5) : 7)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Color.tevariGold.opacity(0.10), in: Capsule())
        .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { animates = true } }
    }
}

private struct ResultCard<Content: View>: View {
    let title: String
    let eyebrow: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(eyebrow).font(.caption.weight(.bold)).foregroundStyle(Color.tevariGold)
            Text(title).font(.system(size: 24, weight: .medium, design: .serif)).foregroundStyle(.white)
            content
        }
        .padding(20)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct ScriptureCard: View {
    let scripture: TevariPrayerPrompt.Scripture
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(scripture.reference).font(.caption.weight(.bold)).foregroundStyle(Color.tevariGold)
            Text(scripture.content).font(.system(size: 15, design: .serif)).foregroundStyle(.white.opacity(0.90))
            Text("YouVersion • \(scripture.bible.abbreviation)").font(.caption2).foregroundStyle(.white.opacity(0.42))
        }
        .padding(.top, 6)
    }
}

private struct ErrorLine: View { let message: String; var body: some View { Text(message).font(.footnote).foregroundStyle(.red.opacity(0.95)) } }

private struct FaithLensStage: View {
    let imageData: Data?
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.black.opacity(0.28))
                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "viewfinder.circle")
                            .font(.system(size: 43, weight: .light))
                            .foregroundStyle(Color.tevariGold)
                        Text("Bring one real moment into view")
                            .font(.system(size: 19, weight: .medium, design: .serif))
                            .foregroundStyle(.white)
                        Text("Use the + beside the message field to open your camera or photo library.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.58))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                }
            }
            .frame(height: 310)
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
            if imageData != nil {
                Label("Your image stays on this phone until you choose Reflect.", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

private struct PhoneCameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var imageData: Data?
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary; picker.delegate = context.coordinator; picker.allowsEditing = false; return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: PhoneCameraPicker; init(parent: PhoneCameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { parent.imageData = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.82); parent.dismiss() }
    }
}

/// PHPicker is presented directly from the explicit + menu. It grants access
/// only to the image the person chooses, so iOS does not need a broad photo
/// library permission prompt.
private struct PhonePhotoLibraryPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var imageData: Data?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhonePhotoLibraryPicker
        init(parent: PhonePhotoLibraryPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { parent.dismiss(); return }
            provider.loadObject(ofClass: UIImage.self) { image, _ in
                let data = (image as? UIImage)?.jpegData(compressionQuality: 0.82)
                DispatchQueue.main.async { self.parent.imageData = data; self.parent.dismiss() }
            }
        }
    }
}

private func hidePhoneKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Account, Siri, and visual language

private struct TevariSettingsView: View {
    @ObservedObject var auth: AuthenticationService
    @ObservedObject var wearables: WearablesService
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsLogout = false
    @State private var confirmsDeletion = false
    @State private var confirmsGoogleDeletion = false
    @State private var showsPasswordDeletion = false
    @State private var deletionError: String?
    var body: some View {
        settingsNavigation
            .preferredColorScheme(.dark)
    }

    private var settingsNavigation: some View {
        NavigationStack {
            settingsList
        }
        .sheet(isPresented: $showsPasswordDeletion) {
            AccountDeletionPasswordView(auth: auth) { result in handleAccountDeletion(result) }
                .presentationDetents([.height(290)])
        }
        .alert("Log out of Tevari?", isPresented: $confirmsLogout) {
            Button("Log out", role: .destructive) { try? auth.signOut(); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You can sign in or continue as a guest again at any time.")
        }
        .alert("Delete your Tevari account?", isPresented: $confirmsDeletion) {
            Button("Delete account", role: .destructive) { Task { await beginAccountDeletion() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes your Tevari sign-in, including a guest account. Tevari does not keep your prayers, photos, stories, or Parallel prompts in an account database. This cannot be undone.")
        }
        .alert("Confirm with Google", isPresented: $confirmsGoogleDeletion) {
            Button("Continue with Google", role: .destructive) { Task { await finishGoogleAccountDeletion() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("For your protection, Google needs to confirm your identity before Tevari can permanently delete this account.")
        }
        .alert("Couldn’t delete account", isPresented: deletionErrorPresented) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionErrorMessage)
        }
    }

    private var settingsList: some View {
            List {
                Section("Your space") {
                    HStack(spacing: 8) {
                        Image(systemName: accountIconName)
                        Text(accountTitle)
                    }
                    if isGuest {
                        Text("Guest access works with every Tevari experience. Create an account later to keep an identity across devices.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Faith background") {
                    FaithBackgroundPicker(wearables: wearables)
                }
                Section("Siri") {
                    Text("Say: “Siri, start a prayer with Tevari,” “Open Faith Lens in Tevari,” “Start a Bible story with Tevari,” or “Open Parallel in Tevari.”")
                        .font(.footnote)
                }
            Section {
                Button("Log out", role: .destructive) { confirmsLogout = true }
                Button("Delete account", role: .destructive) { confirmsDeletion = true }
                    .disabled(auth.isWorking)
            } header: {
                Text("Account")
            } footer: {
                Text("Logging out ends this device’s current Tevari session. Deleting an account permanently removes its Tevari sign-in and cannot be undone.")
            }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tevariMidnight)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }

    private var isGuest: Bool {
        auth.user?.isAnonymous == true
    }

    private var accountIconName: String {
        isGuest ? "person.crop.circle.badge.questionmark" : "person.crop.circle"
    }

    private var accountTitle: String {
        if isGuest { return "Guest session" }
        return auth.user?.displayName ?? auth.user?.email ?? "Signed in"
    }

    private var deletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { isPresented in if !isPresented { deletionError = nil } }
        )
    }

    private var deletionErrorMessage: String {
        deletionError ?? ""
    }

    private func beginAccountDeletion() async {
        handleAccountDeletion(await auth.deleteCurrentAccount())
    }

    private func finishGoogleAccountDeletion() async {
        handleAccountDeletion(await auth.reauthenticateWithGoogleAndDelete())
    }

    private func handleAccountDeletion(_ result: AccountDeletionResult) {
        switch result {
        case .deleted:
            dismiss()
        case .requiresPassword:
            showsPasswordDeletion = true
        case .requiresGoogleSignIn:
            confirmsGoogleDeletion = true
        case .failed(let message):
            deletionError = message
        }
    }
}

private struct FaithBackgroundPicker: View {
    @ObservedObject var wearables: WearablesService

    var body: some View {
        Picker("Perspective", selection: traditionSelection) {
            Text("No preference").tag("general")
            Text("Evangelical").tag("evangelical")
            Text("Catholic").tag("catholic")
            Text("Protestant").tag("mainline")
        }
    }

    private var traditionSelection: Binding<String> {
        Binding(
            get: { wearables.tradition.rawValue },
            set: { rawValue in
                guard let selection = WearablesService.Tradition(rawValue: rawValue) else { return }
                wearables.selectTradition(selection)
            }
        )
    }
}

private struct AccountDeletionPasswordView: View {
    @ObservedObject var auth: AuthenticationService
    let completion: (AccountDeletionResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Confirm your password")
                    .font(.title3.weight(.semibold))
                Text("For your protection, enter your password to permanently delete this Tevari account.")
                    .foregroundStyle(.secondary)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button(role: .destructive) {
                    Task {
                        let result = await auth.deleteCurrentAccount(password: password)
                        if case .deleted = result { dismiss() }
                        completion(result)
                    }
                } label: {
                    HStack { Spacer(); Text(auth.isWorking ? "Deleting…" : "Delete account"); Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(password.isEmpty || auth.isWorking)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SiriInvocationCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 22)).foregroundStyle(Color.tevariSage)
            VStack(alignment: .leading, spacing: 5) {
                Text("Begin with Siri").font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(.white)
                Text("“Siri, start a prayer with Tevari.” You can also ask Siri to open Faith Lens, Story, or Parallel.").font(.footnote).foregroundStyle(.white.opacity(0.60))
            }
        }
        .padding(17).background(Color.tevariSage.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.tevariSage.opacity(0.28), lineWidth: 1))
    }
}

private struct TevariSanctuaryBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.tevariMidnight
                Circle().fill(Color.tevariGold.opacity(0.12)).frame(width: proxy.size.width * 0.8).blur(radius: 80).offset(x: phase ? -110 : -54, y: phase ? -250 : -190)
                Circle().fill(Color.tevariSage.opacity(0.10)).frame(width: proxy.size.width * 0.9).blur(radius: 90).offset(x: phase ? 120 : 62, y: phase ? 390 : 330)
                ArcHalo().stroke(.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [3, 9])).frame(width: proxy.size.width * 1.4, height: proxy.size.width * 1.4).rotationEffect(.degrees(phase ? 21 : -12)).offset(y: -proxy.size.height * 0.38)
            }
            .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { phase = true } }
        }.ignoresSafeArea()
    }
}

private struct ArcHalo: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) * 0.42, startAngle: .degrees(-148), endAngle: .degrees(92), clockwise: false); return path
    }
}

private struct PhonePrimaryButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.system(size: 16, weight: .bold)).frame(maxWidth: .infinity).frame(height: 52).foregroundStyle(Color.tevariMidnight).background(Color.tevariGold.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 17, style: .continuous)).scaleEffect(configuration.isPressed ? 0.98 : 1) } }
private struct PhoneSecondaryButtonStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 46).foregroundStyle(.white).background(.white.opacity(configuration.isPressed ? 0.12 : 0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1)) } }
private struct TevariPressStyle: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.scaleEffect(configuration.isPressed ? 0.965 : 1).animation(.spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed) } }
private struct TevariPromptFieldStyle: TextFieldStyle { func _body(configuration: TextField<_Label>) -> some View { configuration.padding(17).foregroundStyle(.white).background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 19, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1)) } }
