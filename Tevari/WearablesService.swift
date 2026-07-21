import Combine
import Foundation
import AVFoundation
import Speech
import MWDATCore
import MWDATDisplay

/// Owns the live DAT connection for Tevari's internal Developer Mode testing.
/// The iPhone remains authoritative; glasses receive a small display card only
/// after the user starts a session.
@MainActor
final class WearablesService: ObservableObject {
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
    @Published var errorMessage: String?

    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?
    private var sessionErrorTask: Task<Void, Never>?
    private var displayStateToken: AnyListenerToken?
    private var deviceSession: DeviceSession?
    private var display: Display?
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

    init() {
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
        display?.stop()
        deviceSession?.stop()
        isExperienceActive = false
        sessionStatus = "Stopping"
        displayStatus = "Stopping"
    }

    /// Enters Prayer from the active glasses application. This is display-only
    /// until the user explicitly begins a spoken prayer in the next step.
    func openPrayerExperience() {
        glassesRouteTitle = "Prayer"
        prayerStatus = "Ready"
        Task { await sendPrayerEntryCard() }
    }

    func returnToGlassesHome() {
        stopPrayerListening()
        glassesRouteTitle = "Home"
        Task { await sendGlassesHomeCard() }
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
                        await self.sendGlassesHomeCard()
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

    private func sendGlassesHomeCardImmediately() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Tevari", style: .heading)
                    Text("Scripture for the moment you are in.", style: .body, color: .secondary)
                    Button(label: "Pray", style: .primary, iconName: .checkmark, onClick: {
                        Task { @MainActor [service] in service.openPrayerExperience() }
                    })
                    Button(label: "Done", style: .primary, iconName: .checkmark, onClick: {
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

    private func sendPrayerEntryCard() async {
        queueDisplayCard(.prayerEntry)
    }

    private func sendPrayerEntryCardImmediately() async {
        guard let display else { return }
        let service = self
        do {
            try await display.send(
                FlexBox(direction: .column, spacing: 12) {
                    Text("Prayer", style: .heading)
                    Text("Begin when you are ready. Tevari will only use your voice after you explicitly start it.", style: .body, color: .secondary)
                    Button(label: "Start prayer", style: .primary, iconName: .checkmark, onClick: {
                        Task { @MainActor [service] in service.startPrayerListening() }
                    })
                    Text("Tevari listens only while this session is active. Stop at any time.", style: .body, color: .secondary)
                    Button(label: "Back", style: .primary, iconName: .checkmark, onClick: {
                        Task { @MainActor [service] in service.returnToGlassesHome() }
                    })
                    Button(label: "Done", style: .primary, iconName: .checkmark, onClick: {
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
                    Button(label: "Finish prayer", style: .primary, iconName: .checkmark, onClick: {
                        Task { @MainActor [service] in await service.completePrayer() }
                    })
                    Button(label: "Back", style: .primary, iconName: .checkmark, onClick: {
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
                    Button(label: "Back", style: .primary, iconName: .checkmark, onClick: {
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
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw NSError(domain: "Tevari", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech Recognition is unavailable right now."])
        }
        stopPrayerListening()
        prayerTranscript = ""
        let audioSession = AVAudioSession.sharedInstance()
        // Meta's HFP guidance: use the bidirectional category, select the
        // glasses HFP input, then wait for Bluetooth routing to settle.
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        guard let hfpInput = audioSession.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
            throw NSError(domain: "Tevari", code: 2, userInfo: [NSLocalizedDescriptionKey: "Glasses microphone is unavailable. Reconnect your glasses in Meta AI and try again."])
        }
        try audioSession.setPreferredInput(hfpInput)
        prayerStatus = "Connecting glasses microphone"
        try await Task.sleep(for: .seconds(2))
        guard audioSession.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) else {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw NSError(domain: "Tevari", code: 3, userInfo: [NSLocalizedDescriptionKey: "Tevari could not route audio to your glasses microphone."])
        }

        // AVAudioEngine captures the selected route format when constructed.
        audioEngine = AVAudioEngine()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        // The input scope is the microphone's hardware format (16 kHz for
        // glasses HFP), unlike the engine output scope which can be 48 kHz.
        input.installTap(onBus: 0, bufferSize: 1_024, format: input.inputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                    self.prayerTranscript = text
                    if !self.isShowingPrayerPrompt {
                        await self.sendListeningCard()
                    }
                }
                if let error, !self.isFinishingCapture {
                    self.prayerStatus = "Listening stopped"
                    self.errorMessage = "Tevari stopped listening: \(error.localizedDescription)"
                    self.stopPrayerListening()
                }
            }
        }
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
                tradition: "general"
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
                tradition: "general"
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
        displayStateToken = nil
        display = nil
        deviceSession = nil
        sessionStateTask?.cancel()
        sessionStateTask = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
    }
}
