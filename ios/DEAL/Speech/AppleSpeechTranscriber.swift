import Foundation
import AVFoundation
import Speech

/// `SFSpeechRecognizer` + `AVAudioEngine`. Emits an utterance after `pauseThreshold` seconds
/// of silence. Restarts the recognition task when Apple ends it (~1 min limit).
@MainActor
final class AppleSpeechTranscriber: SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pauseTimer: Timer?
    private var latestFull = ""
    private var committedCount = 0
    private var onPartial: (@MainActor (String) -> Void)?
    private var onUtterance: (@MainActor (String) -> Void)?
    private let pauseThreshold: TimeInterval

    private(set) var isRunning = false

    init(locale: Locale = Locale(identifier: "en-US"), pauseThreshold: TimeInterval = 1.4) {
        recognizer = SFSpeechRecognizer(locale: locale)
        self.pauseThreshold = pauseThreshold
    }

    func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return true
        #endif
    }

    func start(onPartial: @escaping @MainActor (String) -> Void,
               onUtterance: @escaping @MainActor (String) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw SpeechError.notAuthorized }
        stop()
        self.onPartial = onPartial
        self.onUtterance = onUtterance

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechError.audio(error.localizedDescription)
        }
        #endif

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        // The tap block runs on a realtime audio thread; it only touches the request,
        // captured via a nonisolated box.
        let box = RequestBox()
        self.requestBox = box
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SpeechError.audio(error.localizedDescription)
        }
        isRunning = true
        startRecognitionTask()
    }

    func stop() {
        guard isRunning || task != nil else { return }
        commitPending()
        isRunning = false
        pauseTimer?.invalidate()
        pauseTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        requestBox?.request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: Private

    private final class RequestBox: @unchecked Sendable {
        var request: SFSpeechAudioBufferRecognitionRequest?
    }
    private var requestBox: RequestBox?

    private func startRecognitionTask() {
        guard isRunning, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        self.request = request
        requestBox?.request = request
        latestFull = ""
        committedCount = 0

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.handle(text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isRunning else { return }
        if let text {
            latestFull = text
            if let partial = UtteranceSegmenter.newText(full: text, committedCount: committedCount) {
                onPartial?(partial)
            }
            schedulePauseCommit()
        }
        if isFinal || failed {
            commitPending()
            task = nil
            request?.endAudio()
            // Apple ends tasks after ~1 minute or on error; keep listening with a fresh task.
            startRecognitionTask()
        }
    }

    private func schedulePauseCommit() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: pauseThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.commitPending() }
        }
    }

    private func commitPending() {
        guard let phrase = UtteranceSegmenter.newText(full: latestFull, committedCount: committedCount) else { return }
        committedCount = latestFull.count
        onPartial?("")
        onUtterance?(phrase)
    }
}
