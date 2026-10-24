import Foundation

/// Live mic -> utterances. Apple Speech tonight; Deepgram (with speaker labels) can conform later.
@MainActor
protocol SpeechTranscriber: AnyObject {
    var isRunning: Bool { get }
    /// Requests mic + speech permissions. Returns false if either is denied.
    func requestAuthorization() async -> Bool
    /// `onPartial` streams the in-progress text; `onUtterance` fires once per finished phrase
    /// (after a pause), which the caller posts to `POST /sessions/:id/events`.
    func start(onPartial: @escaping @MainActor (String) -> Void,
               onUtterance: @escaping @MainActor (String) -> Void) throws
    func stop()
}

enum SpeechError: LocalizedError {
    case unavailable
    case notAuthorized
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition isn't available right now."
        case .notAuthorized: "Microphone or speech recognition permission was denied. Enable it in Settings, or use Scripted mode."
        case .audio(let s): "Audio error: \(s)"
        }
    }
}

/// Pure helper: given the full running transcript of a recognition task and how much of it
/// has already been committed, returns the new uncommitted phrase (trimmed), if any.
enum UtteranceSegmenter {
    static func newText(full: String, committedCount: Int) -> String? {
        guard full.count > committedCount else { return nil }
        let start = full.index(full.startIndex, offsetBy: committedCount)
        let fresh = full[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        return fresh.isEmpty ? nil : fresh
    }
}
