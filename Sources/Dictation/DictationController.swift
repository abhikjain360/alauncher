import AppKit
import Core
import Overlay

/// One dictation, from key-down to its end.
@MainActor
final class DictationSession {
    let generation: Int
    /// Frozen at key-down.
    let config: Config
    let targetBundleID: String?
    let targetPID: pid_t?
    let keyDownAt: Date
    /// Opened while an Ask thread was showing: a follow-up question.
    let isFollowUp: Bool
    let isHandsFree: Bool
    var isRaw = false
    var sendIt = false
    var isRecording = true
    var firstBufferAt: Date?
    var superseded = false
    var cancelled = false
    var recorded = false
    /// Set when the screen locks or sleeps during processing: the result goes to the panel.
    var insertionBlocked: String?
    var record: DictationRecord

    init(
        generation: Int, config: Config, target: NSRunningApplication?, isFollowUp: Bool,
        isHandsFree: Bool = false, keyDownAt: Date = Date()
    ) {
        self.generation = generation
        self.keyDownAt = keyDownAt
        self.config = config
        targetBundleID = target?.bundleIdentifier
        targetPID = target?.processIdentifier
        self.isFollowUp = isFollowUp
        self.isHandsFree = isHandsFree
        record = DictationRecord(mode: .cleanup, targetBundleID: target?.bundleIdentifier, handsFree: isHandsFree, outcome: .failed)
    }
}

/// Runs dictation: key actions in, audio → transcript → cleanup or Ask → insertion out.
@MainActor
final class DictationController {
    static let panelHint = "⏎ insert · ⌘C copy · esc close"

    private let log = Log.main
    private let configStore: ConfigStore
    private var config: Config
    private let busy = BusyFlag()
    private var keyMonitor: KeyMonitor?
    private let audio = AudioCapture()
    private let transcriber: Transcriber
    private let history: DictationHistory
    private let recordingStore: RecordingStore
    private let pill = OverlayPill.shared
    private let panel = TextPanel.shared

    private var generation = 0
    private var session: DictationSession?
    private var processing: Task<Void, Never>?
    private var releasePoll: Timer?
    /// A recording armed by the hold key that hasn't started yet (see `start_delay`).
    private var pendingStart: DispatchWorkItem?
    private var pendingRaw = false
    private var tapRetry: Timer?
    private var askRunner: AskRunner?
    private var askOwnsPanel = false
    private var pillShowsModel = false
    private var modelStatus: TranscriberStatus = .unloaded
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var handsFreeListener: HandsFreeListener?
    private var handsFreeIsOn = false
    private var handsFreeStarting = false
    private var handsFreePaused = false
    private var handsFreeStartGeneration = 0
    private var handsFreeEpoch = 0

    init(configStore: ConfigStore, history: DictationHistory) {
        self.configStore = configStore
        self.history = history
        config = configStore.current
        recordingStore = RecordingStore(limit: config.dictation.recordingsLimit)
        let settings = config.dictation
        weak var controller: DictationController?
        transcriber = Transcriber(model: settings.model, unloadAfter: settings.unloadAfter) { status in
            DispatchQueue.main.async { MainActor.assumeIsolated { controller?.modelStatusChanged(status) } }
        }
        controller = self
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        // Follow config changes, keeping any handler the app installed before us.
        let previous = configStore.onChange
        configStore.onChange = { [weak self] config in
            previous?(config)
            MainActor.assumeIsolated { self?.apply(config) }
        }
        history.limit = config.dictation.historyLimit
        if config.dictation.enabled { startListening() }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.systemInterrupted(notification.name.rawValue) }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.systemResumed(notification.name.rawValue) }
            })
        }
    }

    func stop() {
        guard running else { return }
        running = false
        stopListening()
        cancelProcessing(flash: false)
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        history.flush()
        Task { await transcriber.unload() }
    }

    private func startListening() {
        guard keyMonitor == nil else { return }
        if !Transcriber.modelFilesPresent(model: config.dictation.model) {
            // First run: download (and warm up) in the background.
            pillShowsModel = true
            pill.setState(.loading("downloading speech model"))
        }
        // Load now so the first dictation doesn't wait; it unloads again after `unload_after`.
        transcriber.prepare()
        guard attachTap() else {
            log("dictation: event tap unavailable; grant Accessibility to alauncher (retrying every 5 s)")
            pill.flash("dictation needs Accessibility permission", isError: true, duration: 4)
            scheduleTapRetry()
            return
        }
    }

    /// Creates the tap; false when macOS refuses it (this build lacks Accessibility).
    private func attachTap() -> Bool {
        let monitor = KeyMonitor(bindings: KeyStateMachine.Bindings(config.dictation), busy: busy) { [weak self] action in
            self?.handle(action)
        }
        guard monitor.start() else { return false }
        keyMonitor = monitor
        tapRetry?.invalidate()
        tapRetry = nil
        audio.prepare(deviceSpec: config.dictation.inputDevice)
        log("dictation: listening (hold \(config.dictation.holdKey), raw \(config.dictation.rawChord))")
        if config.dictation.handsFree.enabled { startHandsFree(reason: "config") }
        return true
    }

    /// Picks up an Accessibility grant without a relaunch.
    private func scheduleTapRetry() {
        guard tapRetry == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.running, self.config.dictation.enabled, self.keyMonitor == nil else {
                    self.tapRetry?.invalidate()
                    self.tapRetry = nil
                    return
                }
                _ = self.attachTap()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tapRetry = timer
    }

    private func stopListening() {
        tapRetry?.invalidate()
        tapRetry = nil
        keyMonitor?.stop()
        keyMonitor = nil
        _ = dropPendingStart()
        stopHandsFree(reason: "dictation off", showMessage: true)
        cancelRecording(reason: "dictation stopped", flash: nil)
    }

    private func startHandsFree(reason: String) {
        guard running, config.dictation.enabled, !handsFreeIsOn, !handsFreeStarting else { return }
        handsFreeStarting = true
        handsFreePaused = false
        handsFreeStartGeneration += 1
        let startGeneration = handsFreeStartGeneration
        let settings = config.dictation
        transcriber.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.handsFreeStarting, self.handsFreeStartGeneration == startGeneration else { return }
            self.pill.setState(.loading("downloading voice detector"))
        }
        let onEvent: @Sendable (Int, HandsFreeListenerEvent) -> Void = { [weak self] epoch, event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handsFreeEvent(epoch: epoch, event: event) }
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let listener = try await HandsFreeListener.load(settings: settings, transcriber: self.transcriber, onEvent: onEvent)
                guard self.running, self.handsFreeStarting, self.handsFreeStartGeneration == startGeneration else {
                    await self.closeUnstartedHandsFreeListener(listener)
                    return
                }
                guard await self.prepareHandsFreeListener(listener, startGeneration: startGeneration) else { return }
                let sink: @Sendable ([Float]) -> Void = { [weak listener] samples in listener?.receive(samples) }
                try self.audio.startListening(deviceSpec: settings.inputDevice, sink: sink)
                self.handsFreeListener = listener
                self.handsFreeStarting = false
                self.handsFreeIsOn = true
                self.handsFreePaused = false
                self.pill.setState(.hidden)
                self.pill.flash("hands-free on", duration: 1)
                self.log("hands-free: on (\(reason))")
            } catch {
                guard self.handsFreeStartGeneration == startGeneration else { return }
                self.handsFreeStarting = false
                self.handsFreeIsOn = false
                self.pill.setState(.hidden)
                self.pill.flash(Self.logDescription(error), isError: true, duration: 3)
                self.log("hands-free: off (error)")
            }
        }
    }

    private func prepareHandsFreeListener(_ listener: HandsFreeListener, startGeneration: Int) async -> Bool {
        while true {
            guard running, handsFreeStarting, handsFreeStartGeneration == startGeneration else {
                await closeUnstartedHandsFreeListener(listener)
                return false
            }
            dropHandsFreeRecording()
            handsFreeEpoch += 1
            let epoch = handsFreeEpoch
            await listener.reset(epoch: epoch)
            guard running, handsFreeStarting, handsFreeStartGeneration == startGeneration else {
                await closeUnstartedHandsFreeListener(listener)
                return false
            }
            if handsFreeEpoch == epoch { return true }
        }
    }

    private func closeUnstartedHandsFreeListener(_ listener: HandsFreeListener) async {
        dropHandsFreeRecording()
        handsFreeEpoch += 1
        let epoch = handsFreeEpoch
        await listener.close(epoch: epoch)
        if let current = handsFreeListener { resetHandsFreeListener(current) }
    }

    private func nextHandsFreeEpoch() -> Int {
        handsFreeEpoch += 1
        return handsFreeEpoch
    }

    private func dropHandsFreeRecording() {
        guard let session, session.isHandsFree, session.isRecording else { return }
        session.cancelled = true
        self.session = nil
        busy.value = false
        pill.setState(.hidden)
    }

    private func resetHandsFreeListener(_ listener: HandsFreeListener? = nil) {
        dropHandsFreeRecording()
        guard let listener = listener ?? handsFreeListener else { return }
        let epoch = nextHandsFreeEpoch()
        Task { await listener.reset(epoch: epoch) }
    }

    private func updateHandsFreeListener(settings: DictationSettings) {
        dropHandsFreeRecording()
        guard let listener = handsFreeListener else { return }
        let epoch = nextHandsFreeEpoch()
        Task { await listener.update(settings: settings, epoch: epoch) }
    }

    private func closeHandsFreeListener() {
        dropHandsFreeRecording()
        guard let listener = handsFreeListener else { return }
        handsFreeListener = nil
        let epoch = nextHandsFreeEpoch()
        Task { await listener.close(epoch: epoch) }
    }

    private func stopHandsFree(reason: String, showMessage: Bool) {
        guard handsFreeIsOn || handsFreeStarting else { return }
        handsFreeStartGeneration += 1
        handsFreeStarting = false
        handsFreeIsOn = false
        handsFreePaused = false
        audio.stopListening()
        closeHandsFreeListener()
        if showMessage {
            pill.flash("hands-free off", duration: 1)
        } else {
            pill.setState(.hidden)
        }
        log("hands-free: off (\(reason))")
    }

    private func restartHandsFreeAudio() {
        guard let listener = handsFreeListener, handsFreeIsOn, !handsFreePaused else { return }
        audio.stopListening()
        resetHandsFreeListener(listener)
        let sink: @Sendable ([Float]) -> Void = { [weak listener] samples in listener?.receive(samples) }
        do {
            try audio.startListening(deviceSpec: config.dictation.inputDevice, sink: sink)
        } catch {
            stopHandsFree(reason: "error", showMessage: true)
            pill.flash(Self.logDescription(error), isError: true, duration: 3)
        }
    }

    private func systemResumed(_ reason: String) {
        guard handsFreeIsOn, handsFreePaused, let listener = handsFreeListener, !audio.isRecording else { return }
        do {
            let sink: @Sendable ([Float]) -> Void = { [weak listener] samples in listener?.receive(samples) }
            try audio.startListening(deviceSpec: config.dictation.inputDevice, sink: sink)
            handsFreePaused = false
            resetHandsFreeListener(listener)
            log("hands-free: resumed (\(reason))")
        } catch {
            stopHandsFree(reason: "error", showMessage: true)
            pill.flash(Self.logDescription(error), isError: true, duration: 3)
        }
    }

    private func apply(_ new: Config) {
        guard running else { return }
        let old = config
        config = new
        history.limit = new.dictation.historyLimit
        recordingStore.update(limit: new.dictation.recordingsLimit)
        if new.dictation.enabled != old.dictation.enabled {
            new.dictation.enabled ? startListening() : stopListening()
        }
        if new.dictation.handsFree.enabled != old.dictation.handsFree.enabled, new.dictation.enabled {
            new.dictation.handsFree.enabled ? startHandsFree(reason: "config") : stopHandsFree(reason: "config", showMessage: true)
        } else if new.dictation.handsFree != old.dictation.handsFree, handsFreeIsOn {
            updateHandsFreeListener(settings: new.dictation)
        }
        keyMonitor?.update(bindings: KeyStateMachine.Bindings(new.dictation))
        if new.dictation.model != old.dictation.model || new.dictation.unloadAfter != old.dictation.unloadAfter {
            let transcriber = self.transcriber
            Task { await transcriber.update(model: new.dictation.model, unloadAfter: new.dictation.unloadAfter) }
        }
        if new.dictation.inputDevice != old.dictation.inputDevice, handsFreeIsOn, !handsFreePaused, !audio.isRecording {
            restartHandsFreeAudio()
        } else if new.dictation.inputDevice != old.dictation.inputDevice, !audio.isInUse {
            audio.prepare(deviceSpec: new.dictation.inputDevice)
        }
    }

    // MARK: - Key actions

    private func handle(_ action: KeyAction) {
        switch action {
        case .start:
            scheduleRecording()
        case .switchToRaw:
            if pendingStart != nil { pendingRaw = true }
            if let session, session.isRecording { session.isRaw = true }
        case .stop:
            // Released before the mic started: a tap, shorter than min_duration anyway.
            if dropPendingStart() { return }
            finishRecording()
        case .cancel(let reason):
            // Option+key typing ends here, without the mic ever turning on.
            if dropPendingStart() { return }
            if session?.isRecording == true {
                cancelRecording(reason: reason.rawValue, flash: reason == .cancelKey ? "cancelled" : nil)
            } else if reason == .cancelKey, busy.value {
                cancelProcessing(flash: true)
            }
        }
    }

    /// Starts the recording once the hold key has been down for `start_delay`, so a quick
    /// Option+key combination never turns the mic on. A release or another key first drops it.
    private func scheduleRecording() {
        _ = dropPendingStart()
        let keyDownAt = Date()
        let delay = configStore.current.dictation.startDelay.timeInterval ?? 0
        guard delay > 0 else {
            beginRecording(keyDownAt: keyDownAt)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingStart != nil else { return }
                self.pendingStart = nil
                self.beginRecording(keyDownAt: keyDownAt)
            }
        }
        pendingStart = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Drops an armed recording that hasn't started. True when there was one.
    private func dropPendingStart() -> Bool {
        guard let item = pendingStart else { return false }
        item.cancel()
        pendingStart = nil
        pendingRaw = false
        return true
    }

    private func beginRecording(keyDownAt: Date) {
        if let previous = session {
            if previous.isRecording {
                previous.superseded = true
                if previous.isHandsFree {
                    resetHandsFreeListener()
                } else {
                    audio.cancel()
                }
            } else {
                // Its transcript still reaches history when the transcription finishes.
                previous.superseded = true
                processing?.cancel()
                askRunner?.cancel()
            }
        }
        busy.value = false
        let frozen = configStore.current
        config = frozen
        let followUp = panel.isOpen && askOwnsPanel && askRunner != nil
        if panel.isOpen, !followUp { panel.close() }

        generation += 1
        let session = DictationSession(
            generation: generation, config: frozen,
            target: NSWorkspace.shared.frontmostApplication, isFollowUp: followUp, keyDownAt: keyDownAt
        )
        session.isRaw = pendingRaw
        pendingRaw = false
        self.session = session
        transcriber.prepare()
        if frozen.cleanup.enabled || frozen.ask.backend == .direct {
            CleanupClient.shared.warmUp(baseURL: frozen.cleanup.baseURL)
        }

        let generation = session.generation
        let callbacks = AudioCapture.Callbacks(
            onFirstBuffer: { [weak self] in
                guard let self, let session = self.session, session.generation == generation, session.isRecording else { return }
                session.firstBufferAt = Date()
                self.pillShowsModel = false
                self.pill.setState(.recording)
            },
            onLevel: { [weak self] level in
                guard let self, self.session?.generation == generation, self.session?.isRecording == true else { return }
                self.pill.setLevel(level)
            },
            onLimit: { [weak self] in
                guard let self, self.session?.generation == generation else { return }
                self.log("dictation #\(generation): max duration reached")
                self.keyMonitor?.endRecording()
                self.finishRecording()
            }
        )
        do {
            try audio.start(
                deviceSpec: frozen.dictation.inputDevice,
                maxDuration: frozen.dictation.maxDuration.timeInterval,
                callbacks: callbacks
            )
        } catch {
            log("dictation #\(generation): audio failed: \(Self.logDescription(error))")
            self.session = nil
            keyMonitor?.endRecording()
            pill.flash(String(describing: error), isError: true)
            return
        }
        startReleasePoll()
    }

    private func beginHandsFreeRecording() {
        guard handsFreeIsOn, !handsFreePaused, session?.isRecording != true else { return }
        if let previous = session, !previous.isRecording {
            previous.superseded = true
            processing?.cancel()
            askRunner?.cancel()
        }
        busy.value = false
        let frozen = configStore.current
        config = frozen
        let followUp = panel.isOpen && askOwnsPanel && askRunner != nil
        if panel.isOpen, !followUp { panel.close() }
        generation += 1
        let session = DictationSession(
            generation: generation, config: frozen,
            target: NSWorkspace.shared.frontmostApplication, isFollowUp: followUp,
            isHandsFree: true
        )
        self.session = session
        transcriber.prepare()
        if frozen.cleanup.enabled || frozen.ask.backend == .direct {
            CleanupClient.shared.warmUp(baseURL: frozen.cleanup.baseURL)
        }
    }

    /// Catches a hold-key release the tap never saw (secure input can hide it).
    private func startReleasePoll() {
        releasePoll?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollRelease() }
        }
        RunLoop.main.add(timer, forMode: .common)
        releasePoll = timer
    }

    private func pollRelease() {
        guard let session, session.isRecording else {
            releasePoll?.invalidate()
            releasePoll = nil
            return
        }
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let down = KeyStateMachine.holdIsDown(session.config.dictation.holdKey, flags: flags) { code in
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
        guard !down else { return }
        log("dictation #\(session.generation): hold key up without a release event; stopping")
        keyMonitor?.endRecording()
        finishRecording()
    }

    private func systemInterrupted(_ reason: String) {
        _ = dropPendingStart()
        if handsFreeIsOn, !handsFreePaused {
            handsFreePaused = true
            audio.stopListening()
            resetHandsFreeListener()
        }
        guard let session else { return }
        if session.isRecording {
            keyMonitor?.endRecording()
            cancelRecording(reason: reason, flash: nil)
        } else {
            // Finish the work, but never type into a locked or sleeping session.
            session.insertionBlocked = "screen locked or asleep"
        }
    }

    private func cancelRecording(reason: String, flash: String?) {
        guard let session, session.isRecording else { return }
        releasePoll?.invalidate()
        releasePoll = nil
        audio.cancel()
        if handsFreeListener != nil { resetHandsFreeListener() }
        self.session = nil
        log("dictation #\(session.generation): recording cancelled (\(reason))")
        if let flash {
            pill.flash(flash, duration: 1)
        }
        pill.setState(.hidden)
    }

    private func cancelProcessing(flash: Bool) {
        guard let session, !session.isRecording else { return }
        session.cancelled = true
        processing?.cancel()
        askRunner?.cancel()
        if askOwnsPanel, panel.isOpen { panel.close() }
        busy.value = false
        self.session = nil
        pill.setState(.hidden)
        if flash { pill.flash("cancelled", duration: 1) }
        log("dictation #\(session.generation): processing cancelled")
    }

    // MARK: - Processing

    private func finishRecording() {
        guard let session, session.isRecording else { return }
        session.isRecording = false
        releasePoll?.invalidate()
        releasePoll = nil
        let capture = audio.stop()
        if handsFreeListener != nil { resetHandsFreeListener() }
        let pressed = Date().timeIntervalSince(session.keyDownAt)
        session.record.timings.recording = capture.duration
        session.record.timings.firstBuffer = session.firstBufferAt.map { $0.timeIntervalSince(session.keyDownAt) }

        if pressed < (session.config.dictation.minDuration.timeInterval ?? 0) || capture.samples.isEmpty {
            log(String(format: "dictation #%d: dropped, pressed %.2f s", session.generation, pressed))
            self.session = nil
            pill.setState(.hidden)
            return
        }
        if capture.peakWindowDB < AudioLevels.silenceThresholdDB {
            log(String(format: "dictation #%d: dropped as silent (peak %.1f dBFS)", session.generation, capture.peakWindowDB))
            self.session = nil
            pill.setState(.hidden)
            pill.flash("no speech", duration: 1)
            return
        }

        if session.config.dictation.saveRecordings {
            let name = RecordingStore.fileName(generation: session.generation)
            session.record.audioFile = name
            recordingStore.save(capture.samples, name: name)
        }

        busy.value = true
        pillShowsModel = false
        if case .downloading = modelStatus {
            pill.setState(.loading("downloading speech model"))
        } else {
            pill.setState(.processing)
        }
        let samples = capture.samples
        processing = Task { [weak self] in await self?.process(session, samples: samples) }
    }

    private func finishHandsFreeRecording(_ samples: [Float]) {
        guard let session, session.isHandsFree, session.isRecording else { return }
        session.isRecording = false
        let capture = Self.captureResult(samples)
        session.record.timings.recording = capture.duration
        let pressed = capture.duration
        if pressed < (session.config.dictation.minDuration.timeInterval ?? 0) || capture.samples.isEmpty {
            log(String(format: "dictation #%d: dropped, recorded %.2f s", session.generation, pressed))
            self.session = nil
            pill.setState(.hidden)
            return
        }
        if capture.peakWindowDB < AudioLevels.silenceThresholdDB {
            log(String(format: "dictation #%d: dropped as silent (peak %.1f dBFS)", session.generation, capture.peakWindowDB))
            self.session = nil
            pill.setState(.hidden)
            pill.flash("no speech", duration: 1)
            return
        }
        if session.config.dictation.saveRecordings {
            let name = RecordingStore.fileName(generation: session.generation)
            session.record.audioFile = name
            recordingStore.save(capture.samples, name: name)
        }
        busy.value = true
        pillShowsModel = false
        if case .downloading = modelStatus {
            pill.setState(.loading("downloading speech model"))
        } else {
            pill.setState(.processing)
        }
        processing = Task { [weak self] in await self?.process(session, samples: capture.samples) }
    }

    private static func captureResult(_ samples: [Float]) -> CaptureResult {
        let accumulator = SampleAccumulator(maxDuration: nil)
        samples.withUnsafeBufferPointer { _ = accumulator.append($0) }
        return accumulator.finish()
    }

    private func handsFreeEvent(epoch: Int, event: HandsFreeListenerEvent) {
        guard epoch >= handsFreeEpoch else { return }
        switch event {
        case .segmentStart:
            break
        case .segmentEnd:
            break
        case .headCheck(_, let duration, let kind, _, _):
            if kind == .wake {
                log(String(format: "hands-free: wake detected, head check %.3f s", duration))
                beginHandsFreeRecording()
            }
        case .listeningStart:
            guard let session, session.isHandsFree, session.isRecording else { return }
            pillShowsModel = false
            pill.setState(.listening)
        case .level(let level):
            guard session?.isHandsFree == true, session?.isRecording == true else { return }
            pill.setLevel(level)
        case .dictationEnd(let samples, _):
            finishHandsFreeRecording(samples)
        case .nothingHeard:
            guard let session, session.isHandsFree, session.isRecording else { return }
            session.isRecording = false
            self.session = nil
            busy.value = false
            pill.setState(.hidden)
            pill.flash("nothing heard", duration: 1)
            log("hands-free: nothing heard")
        case .dropped:
            break
        case .sendPhrase:
            Task {
                let pressed = await Inserter.shared.pressReturn(targetPID: nil)
                if pressed {
                    log("hands-free: send phrase pressed Return")
                } else {
                    pill.flash("couldn't press Return", isError: true)
                }
            }
        case .offPhrase:
            stopHandsFree(reason: "voice", showMessage: true)
        case .failed:
            stopHandsFree(reason: "error", showMessage: false)
            pill.flash("voice detector failed", isError: true, duration: 3)
        }
    }

    private func isCurrent(_ session: DictationSession) -> Bool {
        self.session === session && !session.superseded && !session.cancelled
    }

    private func process(_ session: DictationSession, samples: [Float]) async {
        let output: Transcriber.Output
        do {
            output = try await transcriber.transcribe(samples)
        } catch {
            guard isCurrent(session) else { return end(session, outcome: .cancelled) }
            log("dictation #\(session.generation): transcription failed: \(Self.logDescription(error))")
            session.record.note = "transcription failed"
            pill.flash("transcription failed", isError: true)
            return end(session, outcome: .failed)
        }
        session.record.rawText = output.text
        session.record.timings.modelWait = output.loadWait
        session.record.timings.transcription = output.transcription
        guard isCurrent(session) else { return end(session, outcome: session.superseded ? .superseded : .cancelled) }
        pill.setState(.processing)

        let settings = session.config.dictation
        var text = output.text
        if session.isHandsFree {
            if let rest = HandsFreePhrases.afterWakePhrase(in: text, wakePhrases: settings.handsFree.wakePhrases) {
                text = rest
            }
            let stripped = HandsFreePhrases.strippingSendPhrase(from: text, sendPhrases: settings.handsFree.sendPhrases)
            text = stripped.text
            session.sendIt = stripped.sendIt
            if HandsFreePhrases.isOnly(text, phrases: settings.handsFree.offPhrases) {
                stopHandsFree(reason: "voice", showMessage: true)
                session.record.filteredText = text
                return end(session, outcome: .droppedEmpty)
            }
            if TextProcessing.isBlank(text), session.sendIt {
                let pressed = await Inserter.shared.pressReturn(targetPID: session.targetPID)
                if !pressed { pill.flash("couldn't press Return", isError: true) }
                return end(session, outcome: pressed ? .inserted : .failed)
            }
        }
        let filtered = settings.removeFillers ? TextProcessing.removeFillers(text, fillers: settings.fillerWords) : text
        session.record.filteredText = filtered
        guard !TextProcessing.isBlank(filtered) else {
            pill.flash("no speech", duration: 1)
            return end(session, outcome: .droppedEmpty)
        }

        if !session.isRaw, session.config.ask.enabled || session.isFollowUp {
            let question = TextProcessing.askQuestion(in: filtered, prefixes: session.config.ask.prefixes)
            if session.isFollowUp || question != nil {
                return await runAsk(session, question: question ?? filtered)
            }
        }
        guard !session.isRaw, session.config.cleanup.enabled else {
            session.record.mode = .raw
            return await insert(filtered, session: session)
        }

        let cleanupStart = Date()
        do {
            let cleaned = try await CleanupClient.shared.cleanUp(filtered, settings: cleanupSettings(for: session))
            session.record.timings.postProcessing = Date().timeIntervalSince(cleanupStart)
            guard isCurrent(session) else { return end(session, outcome: session.superseded ? .superseded : .cancelled) }
            session.record.cleanedText = cleaned
            await insert(cleaned, session: session)
        } catch {
            session.record.timings.postProcessing = Date().timeIntervalSince(cleanupStart)
            guard isCurrent(session) else { return end(session, outcome: session.superseded ? .superseded : .cancelled) }
            log("dictation #\(session.generation): cleanup failed: \(Self.logDescription(error))")
            session.record.note = "cleanup failed: \(Self.logDescription(error))"
            pill.flash("cleanup failed: typed raw text", isError: true)
            await insert(filtered, session: session)
        }
    }

    private func runAsk(_ session: DictationSession, question: String) async {
        session.record.mode = .ask
        guard !question.isEmpty else {
            pill.flash("no question after the Ask prefix", duration: 1.5)
            return end(session, outcome: .droppedEmpty)
        }
        let runner: AskRunner
        if session.isFollowUp, let existing = askRunner {
            runner = existing
            panel.appendEntry(TextPanel.Entry(heading: question, body: ""))
        } else {
            runner = AskRunner(ask: session.config.ask, cleanup: session.config.cleanup, extraPath: session.config.launcher.extraPath)
            askRunner = runner
            panel.show(entries: [TextPanel.Entry(heading: question, body: "")], hint: Self.panelHint)
            askOwnsPanel = true
        }
        panel.onEnter = { [weak self] answer in self?.insertFromPanel(answer) }
        panel.onClose = { [weak self] in self?.askPanelClosed() }

        let start = Date()
        var streamed = false
        do {
            let answer = try await runner.run(question) { [weak self] delta in
                guard let self, self.isCurrent(session) else { return }
                if !streamed {
                    streamed = true
                    self.pill.setState(.hidden)
                }
                self.panel.appendToLast(delta)
            }
            session.record.timings.postProcessing = Date().timeIntervalSince(start)
            session.record.answer = answer.text
            guard isCurrent(session) else { return end(session, outcome: session.superseded ? .superseded : .cancelled) }
            end(session, outcome: .shownInPanel, note: answer.toolsUsed.isEmpty ? nil : "tools: \(answer.toolsUsed.joined(separator: ","))")
        } catch {
            session.record.timings.postProcessing = Date().timeIntervalSince(start)
            guard isCurrent(session) else { return end(session, outcome: session.superseded ? .superseded : .cancelled) }
            log("dictation #\(session.generation): ask failed: \(Self.logDescription(error))")
            panel.appendToLast("⚠︎ \(error)")
            pill.flash("ask failed", isError: true)
            end(session, outcome: .failed, note: "ask failed: \(Self.logDescription(error))")
        }
    }

    private func cleanupSettings(for session: DictationSession) -> CleanupSettings {
        guard session.isHandsFree else { return session.config.cleanup }
        return session.config.cleanup.applying(session.config.dictation.handsFree.cleanup)
    }

    private func askPanelClosed() {
        askRunner?.cancel()
        askRunner = nil
        askOwnsPanel = false
        if let session, !session.isRecording, session.record.mode == .ask { cancelProcessing(flash: false) }
    }

    private func insertFromPanel(_ text: String) {
        guard !text.isEmpty else { return }
        let settings = configStore.current.dictation.insert
        Task {
            let result = await Inserter.shared.insert(text, targetPID: nil, settings: settings)
            if let aborted = result.aborted {
                log("dictation: panel text not inserted (\(aborted.rawValue))")
                pill.flash("not inserted", isError: true)
            } else {
                log("dictation: inserted \(text.count) chars from the panel by \(result.method?.rawValue ?? "-")")
            }
        }
    }

    /// The insertion transaction: only into the app that was frontmost at key-down (checked here
    /// and again by the Inserter after its modifier wait and before every typed chunk), and never
    /// after the screen locked or slept. Otherwise the text opens in the TextPanel, where Enter
    /// inserts it into whatever is frontmost then.
    private func insert(_ text: String, session: DictationSession) async {
        var reason = session.insertionBlocked
        var remainder: String?
        if reason == nil, !Inserter.shared.canPostEvents { reason = "no permission to type" }
        if reason == nil, NSWorkspace.shared.frontmostApplication?.processIdentifier != session.targetPID {
            reason = "target app changed"
        }
        if reason == nil {
            if panel.isOpen { panel.close() }
            let start = Date()
            let result = await Inserter.shared.insert(
                text, targetPID: session.targetPID, settings: session.config.dictation.insert,
                isAllowed: { session.insertionBlocked == nil }
            )
            session.record.timings.insertion = Date().timeIntervalSince(start)
            switch result.aborted {
            case nil:
                var note = session.record.note
                if result.method == .paste, result.restored == false, session.config.dictation.insert.pasteRestore {
                    note = [note, "clipboard not restored"].compactMap { $0 }.joined(separator: "; ")
                }
                if handsFreeIsOn, let listener = handsFreeListener {
                    await listener.openFollowUp()
                }
                if session.sendIt {
                    if await !Inserter.shared.pressReturn(targetPID: session.targetPID) {
                        note = [note, "couldn't press Return"].compactMap { $0 }.joined(separator: "; ")
                        pill.flash("couldn't press Return", isError: true)
                    } else {
                        log("hands-free: send phrase pressed Return")
                    }
                }
                return end(session, outcome: .inserted, note: note)
            case .cancelled?:
                return end(session, outcome: session.superseded ? .superseded : .cancelled)
            case .blocked?:
                reason = session.insertionBlocked ?? "insertion blocked"
                remainder = result.remainder
            case .targetChanged?:
                guard isCurrent(session) else { return end(session, outcome: .cancelled) }
                reason = "target app changed"
                remainder = result.remainder
            }
        }
        let why = reason ?? "not inserted"
        // After a part-way stop only the untyped rest is offered, so Enter doesn't repeat the start.
        let shown = remainder.flatMap { $0.isEmpty ? nil : $0 } ?? text
        let partial = shown != text
        log("dictation #\(session.generation): not inserting (\(why)\(partial ? ", after \(text.count - shown.count) chars" : "")); showing the panel")
        showInPanel(shown, heading: partial ? "Dictation, the untyped rest (\(why))" : "Dictation (\(why))")
        end(session, outcome: .shownInPanel, note: partial ? "\(why); partly typed" : why)
    }

    private func showInPanel(_ text: String, heading: String) {
        if panel.isOpen { panel.close() }
        askOwnsPanel = false
        panel.show(entries: [TextPanel.Entry(heading: heading, body: text)], hint: Self.panelHint)
        panel.onEnter = { [weak self] body in self?.insertFromPanel(body) }
        panel.onClose = nil
    }

    /// Writes history once, logs timings, and resets the busy state if this is still the live session.
    private func end(_ session: DictationSession, outcome: DictationOutcome, note: String? = nil) {
        // Only dictations that produced a transcript are worth keeping.
        if !session.recorded, !session.record.rawText.isEmpty {
            session.recorded = true
            session.record.outcome = outcome
            if let note { session.record.note = note }
            history.append(session.record)
        }
        let timings = session.record.timings
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "-" }
        log("dictation #\(session.generation): \(session.record.mode.rawValue) \(outcome.rawValue)"
            + " handsFree=\(session.isHandsFree) firstBuffer=\(seconds(timings.firstBuffer)) recording=\(seconds(timings.recording))"
            + " modelWait=\(seconds(timings.modelWait)) transcribe=\(seconds(timings.transcription))"
            + " llm=\(seconds(timings.postProcessing)) insert=\(seconds(timings.insertion))"
            + " rawChars=\(session.record.rawText.count) outChars=\((session.record.answer ?? session.record.cleanedText ?? session.record.filteredText).count)")
        guard self.session === session else { return }
        self.session = nil
        processing = nil
        busy.value = false
        pill.setState(.hidden)
    }

    /// For the log and history notes: never a backend-supplied message, which could echo
    /// private text or part of a key.
    private static func logDescription(_ error: Error) -> String {
        switch error {
        case let error as CleanupError:
            if case .http(let status, _) = error { return "HTTP \(status)" }
            return error.description
        case let error as AskError:
            switch error {
            case .backend: return "opencode reported an error"
            case .processFailed(let status, _): return "opencode exited with status \(status)"
            default: return error.description
            }
        case let error as URLError:
            return "network error \(error.code.rawValue)"
        case let error as CaptureError:
            return error.description
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Model status

    private func modelStatusChanged(_ status: TranscriberStatus) {
        modelStatus = status
        let waiting = session.map { !$0.isRecording } ?? false
        switch status {
        case .downloading(let fraction):
            guard session == nil || waiting else { return }
            let percent = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            pillShowsModel = session == nil
            pill.setState(.loading("downloading speech model" + percent))
        case .loading:
            if waiting { pill.setState(.loading("loading speech model")) }
        case .ready, .unloaded:
            if waiting {
                pill.setState(.processing)
            } else if pillShowsModel, session == nil {
                pillShowsModel = false
                pill.setState(.hidden)
            }
        case .failed(let message):
            pillShowsModel = false
            if session == nil { pill.setState(.hidden) }
            pill.flash("speech model: \(message)", isError: true, duration: 4)
        }
    }

    // MARK: - Launcher commands

    func toggleHandsFree() {
        guard config.dictation.enabled else {
            pill.flash("dictation is off", isError: true)
            return
        }
        if handsFreeIsOn || handsFreeStarting {
            stopHandsFree(reason: "command", showMessage: true)
        } else {
            startHandsFree(reason: "command")
        }
    }

    func copyLastDictation() {
        guard let record = history.records.last else {
            pill.flash("no dictation yet", duration: 1.5)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.bestText, forType: .string)
        pill.flash("copied last dictation", duration: 1.2)
    }

    /// Re-runs the LLM step of the last dictation and inserts into the frontmost app.
    func retryLastDictation() {
        guard let last = history.records.last, !last.rawText.isEmpty else {
            pill.flash("no dictation to retry", duration: 1.5)
            return
        }
        if session?.isRecording == true {
            pill.flash("finish the current dictation first", duration: 1.5)
            return
        }
        if session != nil { cancelProcessing(flash: false) }
        generation += 1
        let frozen = configStore.current
        let session = DictationSession(
            generation: generation, config: frozen, target: NSWorkspace.shared.frontmostApplication,
            isFollowUp: false, isHandsFree: last.handsFree == true
        )
        session.isRecording = false
        session.isRaw = last.mode == .raw
        session.record.rawText = last.rawText
        self.session = session
        busy.value = true
        pill.setState(.processing)
        processing = Task { [weak self] in await self?.reprocess(session, filtered: last.filteredText.isEmpty ? last.rawText : last.filteredText) }
    }

    private func reprocess(_ session: DictationSession, filtered: String) async {
        session.record.filteredText = filtered
        if !session.isRaw, session.config.ask.enabled,
           let question = TextProcessing.askQuestion(in: filtered, prefixes: session.config.ask.prefixes) {
            return await runAsk(session, question: question)
        }
        guard !session.isRaw, session.config.cleanup.enabled else {
            session.record.mode = .raw
            return await insert(filtered, session: session)
        }
        let start = Date()
        do {
            let cleaned = try await CleanupClient.shared.cleanUp(filtered, settings: cleanupSettings(for: session))
            session.record.timings.postProcessing = Date().timeIntervalSince(start)
            guard isCurrent(session) else { return end(session, outcome: .cancelled) }
            session.record.cleanedText = cleaned
            await insert(cleaned, session: session)
        } catch {
            guard isCurrent(session) else { return end(session, outcome: .cancelled) }
            log("dictation #\(session.generation): retry cleanup failed: \(Self.logDescription(error))")
            pill.flash("cleanup failed: \(Self.logDescription(error))", isError: true)
            end(session, outcome: .failed, note: "cleanup failed: \(Self.logDescription(error))")
        }
    }

    var records: [DictationRecord] { history.records }
}
