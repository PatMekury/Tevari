import Combine
import Foundation
import AVFoundation
import Speech
import MWDATCore
import MWDATCamera
import MWDATDisplay
import UIKit

/// Owns the live DAT connection for Tevari's internal Developer Mode testing.
/// The iPhone remains authoritative; glasses receive a small display card only
/// after the user starts a session.
@MainActor
final class WearablesService: ObservableObject {
    enum Tradition: String, CaseIterable {
        case general
        case evangelical
        case catholic
        case mainline

        var label: String {
            switch self {
            case .general: "No preference"
            case .evangelical: "Evangelical"
            case .catholic: "Catholic"
            case .mainline: "Protestant"
            }
        }
    }

    @Published private(set) var registrationStatus = "Not connected"
    @Published private(set) var sessionStatus = "Not started"
    @Published private(set) var displayStatus = "Not started"
    @Published private(set) var availableDeviceNames: [String] = []
    @Published private(set) var hasDisplayCapableGlasses = false
    @Published private(set) var isRegistered = false
    @Published private(set) var isRegistering = false
    @Published private(set) var isExperienceActive = false
    @Published private(set) var requiresGlassesAppUpdate = false
    @Published private(set) var glassesRouteTitle = "Home"
    @Published private(set) var prayerStatus = "Not started"
    @Published private(set) var faithLensStatus = "Not started"
    @Published private(set) var latestFaithLensFrame: UIImage?
    @Published private(set) var faithLensResponse: TevariFaithLensResponse?
    @Published private(set) var faithLensQuestion = ""
    @Published private(set) var storyStatus = "Not started"
    @Published private(set) var storyScene: TevariStoryScene?
    @Published private(set) var tradition: Tradition = .general
    @Published var errorMessage: String?

    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?
    private var sessionErrorTask: Task<Void, Never>?
    private var displayStateToken: AnyListenerToken?
    private var deviceSession: DeviceSession?
    private var display: Display?
    private var cameraStream: MWDATCamera.Stream?
    private var cameraStateToken: AnyListenerToken?
    private var cameraFrameToken: AnyListenerToken?
    private var cameraPhotoToken: AnyListenerToken?
    private var cameraErrorToken: AnyListenerToken?
    private var isRequestingFaithLensCamera = false
    private var hasPresentedFaithLensCameraControls = false
    private var pendingFaithLensQuestion: String?
    private var storyPrompt = ""
    private var hasStartedStoryCapture = false
    private var storyTranscriptUpdateTask: Task<Void, Never>?
    private var faithLensTranscriptUpdateTask: Task<Void, Never>?
    private var storyAudioPlayer: AVAudioPlayer?
    private var storyAudioURL: URL?
    private let faithLensSpeechSynthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    // Recreated after an audio-route change so the engine does not retain the
    // iPhone microphone's format when a glasses HFP microphone is selected.
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var coAuthoringTask: Task<Void, Never>?
    private var prayerTranscript = ""
    private var isSubmittingPrayer = false
    private var isFinishingCapture = false
    private var isRequestingLivePrompt = false
    private var isShowingPrayerPrompt = false
    private var lastPromptWordCount = 0
    private enum SpeechCaptureDestination { case none, prayer, faithLens, story }
    private var speechCaptureDestination: SpeechCaptureDestination = .none
    // DAT accepts one display update at a time. Speech recognition, a live
    // prompt, and a button action can otherwise race and cause the SDK to
    // supersede a card that is still being delivered.
    private enum PendingDisplayCard {
        case home
        case prayerEntry
        case listening(TevariPrayerPrompt?)
        case unavailable
    }
    private var pendingDisplayCard: PendingDisplayCard?
    private var isSendingDisplayCard = false
    /// This must begin listening before the user starts a session. DAT updates
    /// the selector as glasses become available after Meta AI registration.
    private var displayDeviceSelector: AutoDeviceSelector
    private static let traditionDefaultsKey = "tevari.glasses.tradition"

    private var hasSelectedTradition: Bool {
        UserDefaults.standard.string(forKey: Self.traditionDefaultsKey) != nil
    }

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.traditionDefaultsKey),
           let storedTradition = Tradition(rawValue: stored) {
            tradition = storedTradition
        }
        displayDeviceSelector = AutoDeviceSelector(
            wearables: Wearables.shared,
            filter: { $0.supportsDisplay() }
        )
        applyRegistrationState(Wearables.shared.registrationState)
        observeRegistration()
        observeDevices()
    }

    deinit {
        registrationTask?.cancel()
        devicesTask?.cancel()
        sessionStateTask?.cancel()
        sessionErrorTask?.cancel()
    }

    func startRegistration() {
        guard !isRegistered, !isRegistering else { return }
        Task {
            errorMessage = nil
            do {
                try await Wearables.shared.startRegistration()
                print("Tevari DAT registration launched")
            } catch RegistrationError.alreadyRegistered {
                applyRegistrationState(.registered)
                print("Tevari DAT registration already exists")
            } catch let error as RegistrationError {
                errorMessage = registrationErrorMessage(for: error)
                print("Tevari DAT registration failed: \(error.description)")
            } catch {
                errorMessage = error.localizedDescription
                print("Tevari DAT registration failed: \(error.localizedDescription)")
            }
        }
    }

    /// Starts a display-only session. It never requests camera or microphone access.
    func startGlassesExperience() {
        guard deviceSession == nil else { return }

        Task {
            errorMessage = nil
            requiresGlassesAppUpdate = false
            sessionStatus = "Connecting"

            do {
                guard hasDisplayCapableGlasses else {
                    sessionStatus = "No display-capable glasses found"
                    errorMessage = availableDeviceNames.isEmpty
                        ? "Open, wear, and reconnect your glasses in Meta AI, then try again."
                        : "These glasses do not support the Tevari display experience."
                    return
                }
                let session = try Wearables.shared.createSession(deviceSelector: displayDeviceSelector)
                deviceSession = session
                observe(session)
                try session.start()
            } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
                sessionStatus = "Glasses app update required"
                errorMessage = "Tevari needs to update its glasses component before this session can start."
                requiresGlassesAppUpdate = true
                clearStoppedSession()
            } catch {
                sessionStatus = "Could not start"
                errorMessage = error.localizedDescription
                clearStoppedSession()
            }
        }
    }

    func stopGlassesExperience() {
        stopPrayerListening()
        stopFaithLensCamera()
        stopStoryNarration()
        display?.stop()
        deviceSession?.stop()
        isExperienceActive = false
        sessionStatus = "Stopping"
        displayStatus = "Stopping"
    }

    /// Enters Prayer from the active glasses application. This is display-only
    /// until the user explicitly begins a spoken prayer in the next step.
    func openPrayerExperience() {
        // Prayer may be entered from Story after narration. Clear that HFP
        // playback session first so Prayer starts from the same clean state as
        // the known-good home-screen prayer flow.
        stopStoryNarration()
        stopFaithLensCamera()
        stopPrayerListening()
        glassesRouteTitle = "Prayer"
        prayerStatus = "Ready"
        Task { await sendPrayerEntryCard() }
    }

    func returnToGlassesHome() {
        stopPrayerListening()
        stopFaithLensCamera()
        stopStoryNarration()
        glassesRouteTitle = "Home"
        Task { await sendGlassesHomeCard() }
    }

    /// Faith Lens makes the camera state explicit: starting this method only
    /// starts a local glasses preview. Analysis happens later, after a user
    /// asks a question and chooses to capture one frame.
    func openFaithLens() {
        stopPrayerListening()
        glassesRouteTitle = "Faith Lens"
        faithLensStatus = "Ready to start camera"
        faithLensResponse = nil
        Task { await sendFaithLensEntryCard() }
    }

    func openStory() {
        stopFaithLensCamera()
        stopPrayerListening()
        storyTranscriptUpdateTask?.cancel()
        glassesRouteTitle = "Story"
        storyStatus = "Ready for your prompt"
        storyPrompt = ""
        hasStartedStoryCapture = false
        storyScene = nil
        Task { await sendStoryEntryCard() }
    }

    func selectTradition(_ selection: Tradition) {
        tradition = selection
        UserDefaults.standard.set(selection.rawValue, forKey: Self.traditionDefaultsKey)
        Task { await sendGlassesHomeCardImmediately() }
    }

    func startStoryListening() {
        guard !audioEngine.isRunning else { return }
        hasStartedStoryCapture = true
        Task {
            errorMessage = nil
            storyPrompt = ""
            storyStatus = "Preparing glasses microphone"
            guard await requestSpeechAuthorization(), await requestMicrophoneAuthorization() else {
                storyStatus = "Microphone permission needed"
                errorMessage = "Allow Microphone and Speech Recognition for Tevari in iPhone Settings, then try your Story prompt again."
                await sendStoryEntryCard()
                return
            }
            do {
                try await beginGlassesSpeechRecognition(destination: .story)
                storyStatus = "Listening"
                await sendStoryListeningCard()
            } catch {
                storyStatus = "Could not listen"
                errorMessage = "Tevari could not start the glasses microphone: \(error.localizedDescription)"
                await sendStoryEntryCard()
            }
        }
    }

    func finishStoryListening() {
        stopFaithLensListening()
        let prompt = storyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            storyStatus = "No prompt heard"
            errorMessage = "Tevari did not hear a story prompt. Try again with your glasses microphone connected."
            Task { await sendStoryEntryCard() }
            return
        }
        storyStatus = "Prompt ready"
        Task {
            await restoreGlassesMediaRouteAfterStoryCapture()
            await sendStoryPromptReviewCard(prompt)
        }
    }

    func startStory(prompt: String, continuationPassageID: String? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopFaithLensListening()
        storyStatus = "Preparing your story"
        Task { await sendStoryPreparingCard() }
        Task {
            do {
                let scene = try await TevariAPI.storyScene(
                    prompt: trimmed,
                    tradition: tradition.rawValue,
                    continuationPassageID: continuationPassageID
                )
                storyScene = scene
                storyStatus = "Scene ready"
                await sendStorySceneCard(scene)
            } catch {
                storyStatus = "Could not prepare story"
                errorMessage = error.localizedDescription
                await sendStoryEntryCard()
            }
        }
    }

    func playStoryNarration() {
        guard let scene = storyScene else { return }
        storyStatus = "Preparing narration"
        Task {
            do {
                await sendStoryNarrationStartingCard()
                let audioData = try await TevariAPI.storyNarration(scene.narration)
                try await routeStoryNarrationToGlasses()
                let audioURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tevari-story-narration-\(UUID().uuidString).wav")
                try audioData.write(to: audioURL, options: .atomic)
                storyAudioURL = audioURL
                storyAudioPlayer = try AVAudioPlayer(contentsOf: audioURL)
                storyAudioPlayer?.prepareToPlay()
                storyAudioPlayer?.play()
                storyStatus = "Narrating"
                await sendStoryNarratingCard(scene)
            } catch {
                storyStatus = "Narration unavailable"
                errorMessage = error.localizedDescription
                await sendStoryMoreCard(scene)
            }
        }
    }

    func startFaithLensCamera() {
        guard deviceSession != nil, cameraStream == nil, !isRequestingFaithLensCamera else { return }
        isRequestingFaithLensCamera = true
        hasPresentedFaithLensCameraControls = false
        errorMessage = nil
        faithLensStatus = "Requesting camera access"
        Task { [weak self] in
            guard let self else { return }
            await self.sendFaithLensCameraStartingCard()
            await self.beginFaithLensCamera()
        }
    }

    /// Meta glasses camera access is a separate permission from iOS's camera
    /// privacy setting. The DAT SDK opens Meta AI when a grant is needed.
    private func beginFaithLensCamera() async {
        defer { isRequestingFaithLensCamera = false }

        do {
            var permissionStatus = try await Wearables.shared.checkPermissionStatus(.camera)
            if permissionStatus != .granted {
                faithLensStatus = "Allow camera access in Meta AI"
                await sendFaithLensPermissionCard()
                permissionStatus = try await Wearables.shared.requestPermission(.camera)
            }

            guard permissionStatus == .granted else {
                faithLensStatus = "Camera permission needed"
                errorMessage = "Faith Lens needs Camera access in the Meta AI app. Choose Allow once or Allow always, then return to Tevari and start the camera again."
                await sendFaithLensPermissionDeniedCard()
                return
            }

            guard let deviceSession, cameraStream == nil else { return }
            faithLensStatus = "Starting camera"
            guard let stream = try deviceSession.addStream(config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)) else {
                throw NSError(domain: "Tevari", code: 7, userInfo: [NSLocalizedDescriptionKey: "The glasses did not create a camera stream."])
            }
            cameraStream = stream
            cameraStateToken = stream.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.faithLensStatus = state == .streaming ? "Camera live — ask a question" : String(describing: state).capitalized
                    if state == .streaming, !self.hasPresentedFaithLensCameraControls {
                        self.hasPresentedFaithLensCameraControls = true
                        await self.sendFaithLensCameraReadyCard()
                    }
                }
            }
            cameraFrameToken = stream.videoFramePublisher.listen { [weak self] frame in
                let image = frame.makeUIImage()
                Task { @MainActor [weak self] in self?.latestFaithLensFrame = image }
            }
            cameraPhotoToken = stream.photoDataPublisher.listen { [weak self] photo in
                Task { @MainActor [weak self] in await self?.receivedFaithLensCapture(photo.data) }
            }
            cameraErrorToken = stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.faithLensStatus = "Camera unavailable"
                    self?.errorMessage = "Faith Lens camera: \(error.localizedDescription)"
                    await self?.sendFaithLensCameraErrorCard()
                }
            }
            stream.start()
        } catch {
            faithLensStatus = "Camera could not start"
            errorMessage = "Faith Lens could not request glasses-camera access: \(error.localizedDescription)"
            await sendFaithLensCameraErrorCard()
        }
    }

    func captureFaithLens(question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let cameraStream else { return }
        pendingFaithLensQuestion = trimmed
        faithLensStatus = "Capturing this moment"
        guard cameraStream.capturePhoto(format: .jpeg) else {
            faithLensStatus = "Could not capture"
            errorMessage = "Faith Lens could not capture a frame. Keep the glasses open and try again."
            return
        }
        Task { await sendFaithLensReflectingCard() }
    }

    /// Speaks the short, generated reflection only after the user asks to hear it.
    /// The Scripture remains visibly attributed to its licensed Bible source.
    func speakFaithLensResponse() {
        guard let result = faithLensResponse else { return }
        stopFaithLensListening()
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // A playback session follows the selected media output by default.
            // Passing the HFP/A2DP capture option here causes OSStatus -50 on
            // some glasses routes.
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Faith Lens could not prepare audio: \(error.localizedDescription)"
            return
        }
        faithLensSpeechSynthesizer.stopSpeaking(at: .immediate)
        let spokenPrayer = result.prayer.map { " Prayer: \($0)" } ?? ""
        let utterance = AVSpeechUtterance(string: "\(result.response) \(result.scripture.reference). \(result.scripture.content)\(spokenPrayer)")
        utterance.rate = 0.46
        faithLensSpeechSynthesizer.speak(utterance)
    }

    /// Starts a separate, explicit spoken question. It does not keep audio or
    /// the transcript after the user captures a frame or cancels the flow.
    func startFaithLensListening() {
        guard !audioEngine.isRunning else { return }
        Task {
            errorMessage = nil
            faithLensQuestion = ""
            speechCaptureDestination = .faithLens
            guard await requestSpeechAuthorization(), await requestMicrophoneAuthorization() else {
                faithLensStatus = "Microphone permission needed"
                errorMessage = "Allow Microphone and Speech Recognition for Tevari in iPhone Settings, then try Faith Lens again."
                return
            }
            do {
                try await beginGlassesSpeechRecognition(destination: .faithLens)
                faithLensStatus = "Listening for your question"
            } catch {
                faithLensStatus = "Could not listen"
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Starts a spoken Faith Lens question from the glasses display. Audio is
    /// routed to the glasses HFP microphone; iOS performs transcription only
    /// for this active request and never stores it.
    func startFaithLensListeningFromGlasses() {
        guard !audioEngine.isRunning else { return }
        Task {
            errorMessage = nil
            faithLensQuestion = ""
            faithLensStatus = "Preparing glasses microphone"
            guard await requestSpeechAuthorization(), await requestMicrophoneAuthorization() else {
                faithLensStatus = "Microphone permission needed"
                errorMessage = "Allow Microphone and Speech Recognition for Tevari in iPhone Settings, then try your Faith Lens question again."
                await sendFaithLensCameraReadyCard()
                return
            }
            do {
                try await beginGlassesSpeechRecognition(destination: .faithLens)
                faithLensStatus = "Listening for your question"
                await sendFaithLensListeningCard()
            } catch {
                faithLensStatus = "Could not listen"
                errorMessage = "Tevari could not start the glasses microphone: \(error.localizedDescription)"
                await sendFaithLensCameraReadyCard()
            }
        }
    }

    /// Ends transcription and lets the user confirm the words on the glasses
    /// before Tevari captures or sends anything.
    func finishFaithLensListeningFromGlasses() {
        stopFaithLensListening()
        let question = faithLensQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            faithLensStatus = "No question heard"
            errorMessage = "Tevari did not hear a question. Keep the glasses microphone connected and try again."
            Task { await sendFaithLensQuestionNotHeardCard() }
            return
        }
        faithLensStatus = "Question ready"
        Task { await sendFaithLensQuestionReviewCard(question) }
    }

    func sendFaithLensSpokenQuestion() {
        captureFaithLens(question: faithLensQuestion)
    }

    func stopFaithLensListening() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setPreferredInput(nil)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        storyTranscriptUpdateTask?.cancel()
        faithLensTranscriptUpdateTask?.cancel()
        speechCaptureDestination = .none
        if faithLensStatus == "Listening for your question" { faithLensStatus = "Question ready" }
    }

    private func stopStoryNarration() {
        storyAudioPlayer?.stop()
        storyAudioPlayer = nil
        if let storyAudioURL { try? FileManager.default.removeItem(at: storyAudioURL) }
        storyAudioURL = nil
        try? AVAudioSession.sharedInstance().setPreferredInput(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Narration must use the glasses' media route, never the HFP microphone
    /// route. HFP makes iOS show the call surface over the glasses display;
    /// A2DP is the normal glasses-speaker route for spoken media.
    private func routeStoryNarrationToGlasses() async throws {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setPreferredInput(nil)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        try await Task.sleep(for: .milliseconds(450))
        // `.allowBluetoothA2DP` is not a valid option on a playback-only
        // session and produces OSStatus -50. Playback automatically follows
        // the user's selected glasses media route.
        try audioSession.setCategory(.playback, mode: .spokenAudio)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        guard audioSession.currentRoute.outputs.contains(where: { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE }) else {
            throw NSError(
                domain: "Tevari",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Glasses media audio is unavailable. Select your glasses as the iPhone audio output, then try Hear narration again."]
            )
        }
    }

    /// Speech capture uses the glasses' HFP microphone. Before presenting the
    /// Story review/retry controls, return to the same normal media route used
    /// by narration so a following prompt does not inherit call-style state.
    private func restoreGlassesMediaRouteAfterStoryCapture() async {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setPreferredInput(nil)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        try? await Task.sleep(for: .milliseconds(250))
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            // The next capture still has its own route setup. Do not block the
            // prompt-review card if the glasses media route is briefly absent.
        }
    }

    func stopFaithLensCamera() {
        stopFaithLensListening()
        cameraStream?.stop()
        cameraStateToken = nil
        cameraFrameToken = nil
        cameraPhotoToken = nil
        cameraErrorToken = nil
        cameraStream = nil
        hasPresentedFaithLensCameraControls = false
        pendingFaithLensQuestion = nil
        latestFaithLensFrame = nil
        if faithLensStatus != "Not started" { faithLensStatus = "Stopped" }
    }

    private func receivedFaithLensCapture(_ data: Data) async {
        guard let question = pendingFaithLensQuestion else { return }
        pendingFaithLensQuestion = nil
        faithLensStatus = "Reflecting on this moment"
        do {
            let response = try await TevariAPI.faithLens(imageData: data, question: question, tradition: tradition.rawValue)
            faithLensResponse = response
            faithLensStatus = "Reflection ready"
            await sendFaithLensResponseCard(response)
        } catch {
            faithLensStatus = "Could not reflect"
            errorMessage = error.localizedDescription
            await sendFaithLensCameraReadyCard()
        }
    }

    /// The one and only glasses microphone lifecycle. Prayer is the working
    /// reference implementation, so Story and Faith Lens use this exact route
    /// setup—not a parallel "call"-style session—on first prompt and retry.
    private func beginGlassesSpeechRecognition(destination: SpeechCaptureDestination) async throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw NSError(domain: "Tevari", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech Recognition is unavailable right now."])
        }
        // This is deliberately the same reset Prayer has always used.
        stopPrayerListening()
        speechCaptureDestination = destination
        if destination == .prayer { prayerTranscript = "" }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        guard let hfpInput = audioSession.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
            throw NSError(domain: "Tevari", code: 2, userInfo: [NSLocalizedDescriptionKey: "Glasses microphone is unavailable. Reconnect your glasses in Meta AI and try again."])
        }
        try audioSession.setPreferredInput(hfpInput)
        if destination == .prayer { prayerStatus = "Connecting glasses microphone" }
        try await Task.sleep(for: .seconds(2))
        guard audioSession.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) else {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw NSError(domain: "Tevari", code: 3, userInfo: [NSLocalizedDescriptionKey: "Tevari could not route audio to your glasses microphone."])
        }
        // Construct the engine only after HFP settles, so it captures the
        // glasses microphone format rather than retaining the iPhone format.
        audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: input.inputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                    switch destination {
                    case .prayer:
                        self.prayerTranscript = text
                        if !self.isShowingPrayerPrompt { await self.sendListeningCard() }
                    case .faithLens:
                        self.faithLensQuestion = text
                        self.scheduleFaithLensTranscriptUpdate()
                    case .story:
                        self.storyPrompt = text
                        self.scheduleStoryTranscriptUpdate()
                    case .none:
                        break
                    }
                }
                if let error, self.audioEngine.isRunning {
                    if destination == .prayer, !self.isFinishingCapture {
                        self.prayerStatus = "Listening stopped"
                        self.stopPrayerListening()
                    }
                    self.errorMessage = "Tevari stopped listening: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Called only from the explicit Start prayer action on the glasses.
    func startPrayerListening() {
        guard !audioEngine.isRunning else { return }
        Task {
            errorMessage = nil
            isSubmittingPrayer = false
            isFinishingCapture = false
            isRequestingLivePrompt = false
            isShowingPrayerPrompt = false
            lastPromptWordCount = 0
            prayerStatus = "Requesting microphone access"
            guard await requestSpeechAuthorization(), await requestMicrophoneAuthorization() else {
                prayerStatus = "Microphone permission needed"
                errorMessage = "Allow Microphone and Speech Recognition for Tevari in iPhone Settings, then start prayer again."
                await sendPrayerEntryCard()
                return
            }
            do {
                try await beginSpeechRecognition()
                prayerStatus = "Listening"
                startLiveCoAuthoring()
                await sendListeningCard()
            } catch {
                prayerStatus = "Could not listen"
                errorMessage = "Tevari could not start the microphone: \(error.localizedDescription)"
                await sendPrayerEntryCard()
            }
        }
    }

    func stopPrayerListening() {
        silenceTask?.cancel()
        silenceTask = nil
        coAuthoringTask?.cancel()
        coAuthoringTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setPreferredInput(nil)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        isFinishingCapture = false
        isShowingPrayerPrompt = false
        if prayerStatus == "Listening" || prayerStatus == "Thinking" { prayerStatus = "Stopped" }
    }

    func openFirmwareUpdate() {
        Task {
            do { try await Wearables.shared.openFirmwareUpdate() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func openGlassesAppUpdate() {
        Task {
            do { try await Wearables.shared.openDATGlassesAppUpdate() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func observeRegistration() {
        registrationTask = Task {
            for await state in Wearables.shared.registrationStateStream() {
                applyRegistrationState(state)
                if state == .available || state == .unavailable, deviceSession == nil {
                    displayDeviceSelector = AutoDeviceSelector(
                        wearables: Wearables.shared,
                        filter: { $0.supportsDisplay() }
                    )
                }
            }
        }
    }

    private func registrationMessage(for state: RegistrationState) -> String {
        switch state {
        case .unavailable: "Meta AI approval is needed"
        case .available: "Ready to connect"
        case .registering: "Waiting for Meta AI approval"
        case .registered: "Connected to Meta AI"
        @unknown default: "Connection status unavailable"
        }
    }

    private func applyRegistrationState(_ state: RegistrationState) {
        registrationStatus = registrationMessage(for: state)
        isRegistering = state == .registering
        isRegistered = state == .registered
    }

    private func registrationErrorMessage(for error: RegistrationError) -> String {
        switch error {
        case .alreadyRegistered:
            "Tevari is already connected to Meta AI."
        case .configurationInvalid:
            "Tevari's Meta Developer Mode configuration is invalid. Reinstall the current Xcode build and try again."
        case .metaAINotInstalled:
            "Install or update Meta AI, then try connecting again."
        case .networkUnavailable:
            "Meta AI needs an internet connection to approve Tevari."
        case .timeout:
            "Meta AI did not respond in time. Keep it open and try again."
        case .unknown:
            "Meta AI could not complete the connection. Close Tevari and Meta AI, then reopen Meta AI and try again."
        @unknown default:
            "Meta AI returned an unknown registration error."
        }
    }

    private func observeDevices() {
        devicesTask = Task {
            for await identifiers in Wearables.shared.devicesStream() {
                let devices = identifiers.compactMap { identifier in
                    Wearables.shared.deviceForIdentifier(identifier)
                }
                availableDeviceNames = devices.map { $0.nameOrId() }
                hasDisplayCapableGlasses = devices.contains { $0.supportsDisplay() }
            }
        }
    }

    private func observe(_ session: DeviceSession) {
        sessionStateTask = Task { [weak self] in
            for await state in session.stateStream() {
                guard let self, !Task.isCancelled else { return }
                switch state {
                case .idle: sessionStatus = "Ready to start"
                case .starting: sessionStatus = "Connecting"
                case .started:
                    sessionStatus = "Active"
                    await attachDisplay(to: session)
                case .paused:
                    sessionStatus = "Paused by glasses"
                    isExperienceActive = false
                case .stopping: sessionStatus = "Stopping"
                case .stopped:
                    sessionStatus = "Stopped"
                    displayStatus = "Stopped"
                    isExperienceActive = false
                    clearStoppedSession()
                @unknown default:
                    sessionStatus = String(describing: state).capitalized
                }
            }
        }

        sessionErrorTask = Task { [weak self] in
          for await error in session.errorStream() {
                guard let self, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                requiresGlassesAppUpdate = error == .datAppOnTheGlassesUpdateRequired
            }
        }
    }

    private func attachDisplay(to session: DeviceSession) async {
        guard display == nil else { return }
        do {
            let capability = try session.addDisplay()
            display = capability
            displayStateToken = capability.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.displayStatus = String(describing: state).capitalized
                    switch state {
                    case .started:
                        self.isExperienceActive = true
                        await self.sendInitialGlassesSurface()
                    case .stopping, .stopped:
                        self.isExperienceActive = false
                    case .starting:
                        break
                    }
                }
            }
            capability.start()
        } catch {
            displayStatus = "Could not start"
            errorMessage = "Could not start the glasses display: \(error.localizedDescription)"
        }
    }

    /// The first real glasses surface. Each action stays on the glasses until
    /// the user explicitly elects to start a privacy-sensitive capability.
    private func queueDisplayCard(_ card: PendingDisplayCard) {
        pendingDisplayCard = card
        guard !isSendingDisplayCard else { return }
        isSendingDisplayCard = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            while let nextCard = self.pendingDisplayCard {
                self.pendingDisplayCard = nil
                await self.sendDisplayCardImmediately(nextCard)
            }
            self.isSendingDisplayCard = false
        }
    }

    private func sendDisplayCardImmediately(_ card: PendingDisplayCard) async {
        switch card {
        case .home:
            await sendGlassesHomeCardImmediately()
        case .prayerEntry:
            await sendPrayerEntryCardImmediately()
        case .listening(let prompt):
            await sendListeningCardImmediately(prompt: prompt)
        case .unavailable:
            await sendPrayerUnavailableCardImmediately()
        }
    }

    private func sendGlassesHomeCard() async {
        queueDisplayCard(.home)
    }

    private func sendInitialGlassesSurface() async {
        if hasSelectedTradition {
            await sendGlassesHomeCard()
        } else {
            await sendTraditionSelectionCard()
        }
    }

    private func sendGlassesHomeCardImmediately() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Tevari", style: .heading)
                    Text("Scripture for the moment you are in.", style: .body, color: .secondary)
                    Text("Personalized for \(tradition.label).", style: .body, color: .secondary)
                    Button(label: "Pray", style: .primary, onClick: {
                        Task { @MainActor [service] in service.openPrayerExperience() }
                    })
                    Button(label: "Faith Lens", style: .primary, onClick: {
                        Task { @MainActor [service] in service.openFaithLens() }
                    })
                    Button(label: "Story", style: .primary, onClick: {
                        Task { @MainActor [service] in service.openStory() }
                    })
                    Button(label: "Done", style: .primary, onClick: {
                        Task { @MainActor [service] in service.stopGlassesExperience() }
                    })
                }
                .padding(24)
                .background(.card)
            )
        } catch {
            errorMessage = "Could not send the Tevari display card: \(error.localizedDescription)"
        }
    }

    private func sendTraditionSelectionCard() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Faith background", style: .heading)
                    Text("Choose the perspective Tevari should use for prayer, stories, and reflections.", style: .body, color: .secondary)
                    Button(label: "Evangelical", style: .primary, onClick: {
                        Task { @MainActor [service] in service.selectTradition(.evangelical) }
                    })
                    Button(label: "Catholic", style: .primary, onClick: {
                        Task { @MainActor [service] in service.selectTradition(.catholic) }
                    })
                    Button(label: "Protestant", style: .primary, onClick: {
                        Task { @MainActor [service] in service.selectTradition(.mainline) }
                    })
                    Button(label: "No preference", style: .primary, onClick: {
                        Task { @MainActor [service] in service.selectTradition(.general) }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show tradition selection: \(error.localizedDescription)" }
    }

    private func sendPrayerEntryCard() async {
        queueDisplayCard(.prayerEntry)
    }

    private func sendFaithLensEntryCard() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Faith Lens", style: .heading)
                    Text("Start the camera, then ask Tevari about what is before you. One frame is captured only when you ask.", style: .body, color: .secondary)
                    Button(label: "Start camera", style: .primary, onClick: {
                        Task { @MainActor [service] in service.startFaithLensCamera() }
                    })
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens: \(error.localizedDescription)" }
    }

    /// Faith Lens is operable entirely from the glasses. The phone can still
    /// show a private live preview, but it is not required to capture a moment.
    private func sendFaithLensPermissionCard() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Faith Lens", style: .heading)
                    Text("Allow Camera access in Meta AI, then return here. Tevari uses your glasses camera only for the moment you choose to capture.", style: .body, color: .secondary)
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens permission status: \(error.localizedDescription)" }
    }

    private func sendFaithLensCameraStartingCard() async {
        guard let display else { return }
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Faith Lens", style: .heading)
                    Text("Starting your glasses camera…", style: .body, color: .secondary)
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens start status: \(error.localizedDescription)" }
    }

    private func sendFaithLensPermissionDeniedCard() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Camera permission needed", style: .heading)
                    Text("In Meta AI, allow Tevari to use your glasses camera. Then come back and choose Start camera.", style: .body, color: .secondary)
                    Button(label: "Try again", style: .primary, onClick: {
                        Task { @MainActor [service] in service.startFaithLensCamera() }
                    })
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens permission result: \(error.localizedDescription)" }
    }

    private func sendFaithLensCameraReadyCard() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Faith Lens is live", style: .heading)
                    Text("Look at the moment before you, then choose the reflection you need. Tevari captures one photo only after you choose.", style: .body, color: .secondary)
                    Button(label: "Find Scripture", style: .primary, onClick: {
                        Task { @MainActor [service] in service.captureFaithLens(question: "What Scripture speaks to this moment?") }
                    })
                    Button(label: "Offer a prayer", style: .primary, onClick: {
                        Task { @MainActor [service] in service.captureFaithLens(question: "What is a short prayer for this moment?") }
                    })
                    Button(label: "Ask a question", style: .primary, onClick: {
                        Task { @MainActor [service] in service.startFaithLensListeningFromGlasses() }
                    })
                    Button(label: "Stop camera", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens camera controls: \(error.localizedDescription)" }
    }

    // The current public Display DSL has no animation primitive. This strong,
    // high-contrast listening state is sent once rather than repeatedly
    // replacing the glasses view while audio is being transcribed.
    private func sendFaithLensListeningStartingCard() async {
        guard let display else { return }
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("● Preparing microphone", style: .heading)
                    Text("Connecting to your glasses microphone…", style: .body, color: .secondary)
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens microphone status: \(error.localizedDescription)" }
    }

    private func sendFaithLensListeningCard() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("● Listening", style: .heading)
                    Text("Speak your question naturally. Tevari is listening through your glasses microphone.", style: .body, color: .secondary)
                    if !faithLensQuestion.isEmpty {
                        Text(faithLensQuestion, style: .body)
                    }
                    Button(label: "I'm done speaking", style: .primary, onClick: {
                        Task { @MainActor [service] in service.finishFaithLensListeningFromGlasses() }
                    })
                    Button(label: "Cancel", style: .primary, onClick: {
                        Task { @MainActor [service] in
                            service.stopFaithLensListening()
                            await service.sendFaithLensCameraReadyCard()
                        }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens listening state: \(error.localizedDescription)" }
    }

    private func sendFaithLensQuestionReviewCard(_ question: String) async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("I heard", style: .heading)
                    Text(question, style: .body)
                    Text("Send this question with one captured moment?", style: .body, color: .secondary)
                    Button(label: "Send", style: .primary, onClick: {
                        Task { @MainActor [service] in service.sendFaithLensSpokenQuestion() }
                    })
                    Button(label: "Try again", style: .primary, onClick: {
                        Task { @MainActor [service] in service.startFaithLensListeningFromGlasses() }
                    })
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens question review: \(error.localizedDescription)" }
    }

    private func sendFaithLensQuestionNotHeardCard() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("I didn't hear a question", style: .heading)
                    Text("Keep your glasses connected and speak a little closer to the microphone, then try again.", style: .body, color: .secondary)
                    Button(label: "Try again", style: .primary, onClick: {
                        Task { @MainActor [service] in service.startFaithLensListeningFromGlasses() }
                    })
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens retry state: \(error.localizedDescription)" }
    }

    private func sendFaithLensReflectingCard() async {
        guard let display else { return }
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Faith Lens", style: .heading)
                    Text("Reflecting on this moment…", style: .body, color: .secondary)
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens reflection status: \(error.localizedDescription)" }
    }

    private func sendFaithLensCameraErrorCard() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Camera unavailable", style: .heading)
                    Text("Keep your glasses open, worn, and connected in Meta AI, then try again.", style: .body, color: .secondary)
                    Button(label: "Try again", style: .primary, onClick: {
                        Task { @MainActor [service] in service.startFaithLensCamera() }
                    })
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens camera error: \(error.localizedDescription)" }
    }

    private func sendFaithLensResponseCard(_ result: TevariFaithLensResponse) async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Faith Lens", style: .heading)
                    Text(result.response, style: .body)
                    Text("Scripture", style: .heading)
                    Text(result.scripture.reference, style: .body, color: .secondary)
                    Text(result.scripture.content, style: .body)
                    if let prayer = result.prayer { Text("Prayer: \(prayer)", style: .body, color: .secondary) }
                    Button(label: "Done", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Faith Lens response: \(error.localizedDescription)" }
    }

    private func sendStoryEntryCard() async {
        guard let display else { return }
        // This is intentionally the same clean surface as the first Story
        // prompt. A retry must never reopen the microphone from a review card.
        hasStartedStoryCapture = false
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Bible Story", style: .heading)
                    Text("Ask for a person, a moment, or what you need today. Tevari creates one short scene, then grounds it in Scripture.", style: .body, color: .secondary)
                    Button(label: "Speak a prompt", style: .primary, onClick: {
                        Task { @MainActor [service] in service.startStoryListening() }
                    })
                    Button(label: "Story for courage", style: .primary, onClick: {
                        Task { @MainActor [service] in
                            service.startStory(prompt: "Tell me a Bible story about courage when I feel afraid.")
                        }
                    })
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Story: \(error.localizedDescription)" }
    }

    private func sendStoryListeningStartingCard() async {
        guard let display else { return }
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("● Preparing microphone", style: .heading)
                    Text("Resetting your glasses microphone for the next prompt…", style: .body, color: .secondary)
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not prepare Story microphone: \(error.localizedDescription)" }
    }

    private func sendStoryListeningCard() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("● Listening", style: .heading)
                    Text("Tell Tevari the Bible story you want to hear through your glasses microphone.", style: .body, color: .secondary)
                    if !storyPrompt.isEmpty {
                        Text(storyPrompt, style: .body)
                    }
                    Button(label: "I'm done speaking", style: .primary, onClick: {
                        Task { @MainActor [service] in service.finishStoryListening() }
                    })
                    Button(label: "Cancel", style: .primary, onClick: {
                        Task { @MainActor [service] in
                            service.stopFaithLensListening()
                            await service.sendStoryEntryCard()
                        }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Story listening state: \(error.localizedDescription)" }
    }

    /// Display updates are deliberately throttled so each partial transcript
    /// replaces the glasses card cleanly instead of fighting the DAT display
    /// transport on every speech-recognition callback.
    private func scheduleStoryTranscriptUpdate() {
        storyTranscriptUpdateTask?.cancel()
        storyTranscriptUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled,
                  self.speechCaptureDestination == .story,
                  self.audioEngine.isRunning else { return }
            await self.sendStoryListeningCard()
        }
    }

    private func scheduleFaithLensTranscriptUpdate() {
        faithLensTranscriptUpdateTask?.cancel()
        faithLensTranscriptUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled,
                  self.speechCaptureDestination == .faithLens,
                  self.audioEngine.isRunning else { return }
            await self.sendFaithLensListeningCard()
        }
    }

    private func sendStoryPromptReviewCard(_ prompt: String) async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("I heard", style: .heading)
                    Text(prompt, style: .body)
                    Text("Send this to Tevari?", style: .body, color: .secondary)
                    Button(label: "Send", style: .primary, onClick: {
                        Task { @MainActor [service] in service.startStory(prompt: prompt) }
                    })
                    Button(label: "Try again", style: .primary, onClick: {
                        Task { @MainActor [service] in service.openStory() }
                    })
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in await service.sendStoryEntryCard() }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Story prompt review: \(error.localizedDescription)" }
    }

    private func sendStoryPreparingCard() async {
        guard let display else { return }
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Tevari Story", style: .heading)
                    Text("Creating your next scene and finding the Scripture…", style: .body, color: .secondary)
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Story status: \(error.localizedDescription)" }
    }

    private func sendStoryNarrationStartingCard() async {
        guard let display else { return }
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Tevari Story", style: .heading)
                    Text("Preparing the narration…", style: .body, color: .secondary)
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show narration status: \(error.localizedDescription)" }
    }

    private func sendStoryNarratingCard(_ scene: TevariStoryScene) async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Now telling", style: .heading)
                    Text(scene.title, style: .body, color: .secondary)
                    Text("The narration is playing through your selected glasses audio.", style: .body)
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in
                            service.stopStoryNarration()
                            await service.sendStoryMoreCard(scene)
                        }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show narration playback: \(error.localizedDescription)" }
    }

    private func sendStorySceneCard(_ scene: TevariStoryScene) async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Your story", style: .heading)
                    Text(String(scene.guide.prefix(220)), style: .body)
                    Text(scene.title, style: .body, color: .secondary)
                    Text("Scripture · \(scene.scripture.reference)", style: .body, color: .secondary)
                    Button(label: "Continue", style: .primary, onClick: {
                        Task { @MainActor [service] in
                            service.startStory(
                                prompt: "Continue this Bible story.",
                                continuationPassageID: scene.scripture.id
                            )
                        }
                    })
                    Button(label: "More", style: .primary, onClick: {
                        Task { @MainActor [service] in await service.sendStoryMoreCard(scene) }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Story scene: \(error.localizedDescription)" }
    }

    private func sendStoryMoreCard(_ scene: TevariStoryScene) async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("More", style: .heading)
                    Text(scene.title, style: .body, color: .secondary)
                    Button(label: "Hear narration", style: .primary, onClick: {
                        Task { @MainActor [service] in service.playStoryNarration() }
                    })
                    Button(label: "Read Scripture", style: .primary, onClick: {
                        Task { @MainActor [service] in await service.sendStoryScriptureCard(scene) }
                    })
                    Button(label: "Pray from this", style: .primary, onClick: {
                        Task { @MainActor [service] in service.openPrayerExperience() }
                    })
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in
                            service.stopStoryNarration()
                            service.storyScene = nil
                            await service.sendStoryEntryCard()
                        }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Story options: \(error.localizedDescription)" }
    }

    private func sendStoryScriptureCard(_ scene: TevariStoryScene) async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Scripture", style: .heading)
                    Text(scene.scripture.reference, style: .body, color: .secondary)
                    Text(scene.scripture.content, style: .body)
                    Text("NIV11 · YouVersion", style: .body, color: .secondary)
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in await service.sendStoryMoreCard(scene) }
                    })
                }.padding(24).background(.card)
            )
        } catch { errorMessage = "Could not show Story Scripture: \(error.localizedDescription)" }
    }

    private func sendPrayerEntryCardImmediately() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Prayer", style: .heading)
                    Text("Begin when you are ready. Tevari will only use your voice after you explicitly start it.", style: .body, color: .secondary)
                    Button(label: "Start prayer", style: .primary, onClick: {
                        Task { @MainActor [service] in service.startPrayerListening() }
                    })
                    Text("Tevari listens only while this session is active. Stop at any time.", style: .body, color: .secondary)
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                    Button(label: "Done", style: .primary, onClick: {
                        Task { @MainActor [service] in service.stopGlassesExperience() }
                    })
                }
                .padding(24)
                .background(.card)
            )
        } catch {
            errorMessage = "Could not show the Tevari prayer entry: \(error.localizedDescription)"
        }
    }

    private func sendListeningCard(prompt: TevariPrayerPrompt? = nil) async {
        queueDisplayCard(.listening(prompt))
    }

    private func sendListeningCardImmediately(prompt: TevariPrayerPrompt? = nil) async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    if let prompt {
                        Text("Scripture", style: .heading)
                        Text(prompt.scripture.reference, style: .body, color: .secondary)
                        Text(prompt.scripture.content, style: .body)
                        Text("Bible text via YouVersion • \(prompt.scripture.bible.title) (\(prompt.scripture.bible.abbreviation))", style: .body, color: .secondary)
                        Text("Prayer prompt", style: .heading)
                        Text(prompt.prompt, style: .body, color: .secondary)
                    } else {
                        Text("Listening", style: .heading)
                        Text("Keep praying. Tevari will quietly offer Scripture and a short prompt once it has enough context.", style: .body, color: .secondary)
                    }
                    if prompt == nil, !prayerTranscript.isEmpty {
                        Text(prayerTranscript, style: .body, color: .secondary)
                    }
                    Button(label: "Finish prayer", style: .primary, onClick: {
                        Task { @MainActor [service] in await service.completePrayer() }
                    })
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in
                            service.stopPrayerListening()
                            await service.sendPrayerEntryCard()
                        }
                    })
                }
                .padding(24)
                .background(.card)
            )
        } catch {
            errorMessage = "Could not update the Tevari prayer display: \(error.localizedDescription)"
        }
    }

    private func sendPrayerUnavailableCard() async {
        queueDisplayCard(.unavailable)
    }

    private func sendPrayerUnavailableCardImmediately() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Prayer", style: .heading)
                    Text("Tevari could not prepare Scripture and a prayer prompt right now.", style: .body, color: .secondary)
                    Button(label: "Back", style: .primary, onClick: {
                        Task { @MainActor [service] in await service.sendPrayerEntryCard() }
                    })
                }
                .padding(24)
                .background(.card)
            )
        } catch {
            errorMessage = "Could not update the Tevari prayer display: \(error.localizedDescription)"
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func beginSpeechRecognition() async throws {
        try await beginGlassesSpeechRecognition(destination: .prayer)
    }

    /// Keeps listening while a person prays. The first prompt is delayed long
    /// enough to establish context; later prompts are paced to avoid flicker
    /// or interrupting the prayer with constant suggestions.
    private func startLiveCoAuthoring() {
        coAuthoringTask?.cancel()
        coAuthoringTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                guard let self, self.audioEngine.isRunning else { return }
                await self.requestLivePrayerPromptIfReady()
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    private func requestLivePrayerPromptIfReady() async {
        guard !isSubmittingPrayer, !isRequestingLivePrompt, audioEngine.isRunning else { return }
        let transcript = prayerTranscript
        let wordCount = transcript.split(whereSeparator: { $0.isWhitespace }).count

        // Do not turn an opening fragment ("Lord, I...") into an invented
        // prayer. Require enough new language to understand the concern.
        guard wordCount >= 8, wordCount >= lastPromptWordCount + 5 else { return }

        isRequestingLivePrompt = true
        lastPromptWordCount = wordCount
        do {
            let response = try await TevariAPI.prayerContinuation(
                history: [.spoken(transcript)],
                tradition: tradition.rawValue
            )
            guard audioEngine.isRunning, !isFinishingCapture else { return }
            prayerStatus = "Listening with prompt"
            isShowingPrayerPrompt = true
            await sendListeningCard(prompt: response)
        } catch {
            // Keep the prayer private on the phone and keep listening. A
            // transient service problem must not end the user's prayer.
            errorMessage = error.localizedDescription
        }
        isRequestingLivePrompt = false
    }

    /// Ends explicit microphone capture and submits exactly the words captured
    /// in this session. Both the Finish button and a sustained pause use it.
    private func completePrayer() async {
        guard !isSubmittingPrayer else { return }
        guard !prayerTranscript.isEmpty else {
            stopPrayerListening()
            return
        }
        isSubmittingPrayer = true
        isFinishingCapture = true
        silenceTask?.cancel()
        silenceTask = nil
        coAuthoringTask?.cancel()
        coAuthoringTask = nil
        prayerStatus = "Preparing prayer prompt"
        recognitionRequest?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        let transcript = prayerTranscript
        do {
            let response = try await TevariAPI.prayerContinuation(
                history: [.spoken(transcript)],
                tradition: tradition.rawValue
            )
            prayerStatus = "Prompt ready"
            isShowingPrayerPrompt = true
            await sendListeningCard(prompt: response)
        } catch {
            prayerStatus = "Prayer saved on iPhone"
            errorMessage = error.localizedDescription
            await sendPrayerUnavailableCard()
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setPreferredInput(nil)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        isSubmittingPrayer = false
    }

    private func clearStoppedSession() {
        stopFaithLensCamera()
        displayStateToken = nil
        display = nil
        deviceSession = nil
        sessionStateTask?.cancel()
        sessionStateTask = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
    }
}
