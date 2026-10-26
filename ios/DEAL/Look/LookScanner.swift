import CoreGraphics
import Foundation
import Observation

/// Look mode's brains. Watches the frame source, decides when the wearer is really looking at a
/// product, asks the backend what it is and what it sells for, and publishes one `highlight` for
/// the overlay (LookView) and the glasses card. Gestures act on that highlight.
///
/// It must not highlight everything in view, so a highlight needs ALL of:
///   1. Look mode switched on (`isEnabled`, off by default).
///   2. Dwell: one salient object near the frame center (where the head points) held steady for
///      `LookTuning.dwell`. Tiny, huge and edge-touching boxes don't count, and a head turn
///      (motion above `motionThreshold`) restarts the dwell.
///   3. Not seen recently: the crop's perceptual hash (and box) and the identified name are kept in
///      a short memory, so the same thing isn't re-identified every second, and a dismissed item
///      stays quiet for 5 minutes.
///   4. `/look/identify` says `is_product` with confidence ≥ 0.6. At most one identify in flight,
///      and at most one every `identifyInterval`.
///   5. No other highlight showing.
@MainActor
@Observable
final class LookScanner {
    enum Status: Equatable {
        case off
        case starting
        case scanning
        /// Holding on a candidate; `progress` 0…1 of the dwell.
        case dwelling(progress: Double)
        case identifying
        case showing
        case failed(String)

        var label: String {
            switch self {
            case .off: "Look off"
            case .starting: "Starting camera"
            case .scanning: "Scanning"
            case .dwelling: "Looking"
            case .identifying: "Identifying"
            case .showing: "Found"
            case .failed(let message): message
            }
        }
    }

    /// Expanded detail pages, cycled by `.next` / `.previous`.
    enum DetailPage: Int, CaseIterable {
        case price, sources, negotiate

        var title: String {
            switch self {
            case .price: "Market price"
            case .sources: "Sources"
            case .negotiate: "Negotiate"
            }
        }
    }

    private(set) var isEnabled = false
    private(set) var status: Status = .off
    private(set) var highlight: LookHighlight?
    /// The item left view; the overlay fades it and it clears after `LookTuning.lostFade`.
    private(set) var highlightLost = false
    private(set) var priceError: String?
    /// A problem worth showing in the status pill ("Can't reach DEAL"); cleared by the next answer.
    private(set) var notice: String?
    private(set) var page: DetailPage = .price
    /// The full market research (`/research/preview`), started the first time the window expands.
    private(set) var research: ResearchPreview?
    private(set) var researchLoading = false
    private(set) var researchError: String?
    /// Latest camera frame for the live view, and its pixel size.
    private(set) var preview: CGImage?
    private(set) var frameSize: CGSize = .zero

    let frames: LookFrameSource
    let gestures: LookGestureSource?
    private let api: APIClient
    private let vision = LookVision()

    /// `.negotiate` on a highlight. LookView starts the session (it owns the AppModel).
    var onNegotiate: ((LookHighlight) -> Void)?
    /// Called whenever the glasses card should change (identification, price, expanded, page), and
    /// with `nil` when the highlight goes away. Not called for box moves.
    var onGlassesUpdate: ((LookHighlight?) -> Void)?

    // Dwell and gating state
    private var analyzing = false
    private var dwellBox: CGRect?
    private var dwellStart: TimeInterval = 0
    private var lastIdentifyStart: TimeInterval = -.infinity
    private var identifying = false
    private var trackedBox: CGRect?
    private var lastSeen: TimeInterval = 0
    private var highlightHash: UInt64?
    private var memory: [Memory] = []
    private var identifyTask: Task<Void, Never>?
    private var priceTask: Task<Void, Never>?
    private var researchTask: Task<Void, Never>?
    private var glassesKey: String?

    private struct Memory {
        enum Kind { case rejected, shown, dismissed }
        var kind: Kind
        var hash: UInt64?
        var box: CGRect?
        var name: String?
        var until: TimeInterval
    }

    init(frames: LookFrameSource, gestures: LookGestureSource?, api: APIClient) {
        self.frames = frames
        self.gestures = gestures
        self.api = api
    }

    // MARK: On / off

    func setEnabled(_ on: Bool) async {
        guard on != isEnabled else { return }
        isEnabled = on
        if on {
            await start()
        } else {
            stop()
        }
    }

    private func start() async {
        status = .starting
        frames.onFrame = { [weak self] frame in self?.handle(frame) }
        gestures?.onGesture = { [weak self] gesture in self?.handle(gesture) }
        do {
            if !frames.isRunning { try await frames.start() }
            guard isEnabled else { return }
            status = .scanning
        } catch {
            status = .failed("Camera unavailable")
            isEnabled = false
            frames.onFrame = nil
            return
        }
        if let gestures, !gestures.isActive {
            // Gestures are a bonus: the on-screen buttons still work without them.
            try? await gestures.start()
        }
    }

    /// Stops the camera and clears everything (Look off, or leaving the screen).
    func stop() {
        isEnabled = false
        frames.onFrame = nil
        frames.stop()
        gestures?.stop()
        gestures?.onGesture = nil
        identifyTask?.cancel()
        identifying = false
        clearHighlight(remember: true)
        resetDwell()
        preview = nil
        status = .off
    }

    // MARK: Frames

    private func handle(_ frame: LookFrame) {
        // Vision runs off the main actor; drop frames while it's busy.
        guard isEnabled, !analyzing else { return }
        analyzing = true
        let tracking = highlight != nil || identifying
        Task {
            let analysis = await vision.analyze(frame, candidates: !tracking)
            analyzing = false
            apply(analysis, frame: frame)
        }
    }

    private func apply(_ a: LookVision.Analysis, frame: LookFrame) {
        guard isEnabled else { return }
        preview = a.preview
        frameSize = a.size
        let now = frame.timestamp
        pruneMemory(now)

        if highlight != nil || identifying {
            follow(a, now: now)
            return
        }

        // 2. Dwell: a head turn restarts it.
        if a.motion > LookTuning.motionThreshold {
            resetDwell()
            status = .scanning
            return
        }
        guard let candidate = Self.pickCandidate(a.candidates) else {
            resetDwell()
            status = .scanning
            return
        }
        if let box = dwellBox, box.iou(candidate) >= LookTuning.stableIoU {
            dwellBox = box.lerp(candidate, 0.3)
        } else {
            dwellBox = candidate
            dwellStart = now
        }
        let progress = min(1, (now - dwellStart) / LookTuning.dwell)
        status = .dwelling(progress: progress)
        // 4. Rate limit: one in flight, one every `identifyInterval`.
        guard progress >= 1, let box = dwellBox, now - lastIdentifyStart >= LookTuning.identifyInterval else { return }
        identify(frame, box: box, now: now)
    }

    /// Keeps the box on the item while it's in view; fades and clears it once it's gone.
    private func follow(_ a: LookVision.Analysis, now: TimeInterval) {
        if let box = a.tracked, a.trackConfidence >= LookTuning.trackConfidence, Self.inView(box) {
            let smoothed = trackedBox.map { $0.lerp(box, 0.6) } ?? box
            trackedBox = smoothed
            highlight?.box = smoothed
            lastSeen = now
            if highlightLost { highlightLost = false }
            return
        }
        let gone = now - lastSeen
        if gone > 0.3, highlight != nil, !highlightLost { highlightLost = true }
        if gone > LookTuning.lostFade {
            if identifying {
                // Looked away before the backend answered: drop it.
                identifyTask?.cancel()
                identifying = false
                vision.stopTracking()
                trackedBox = nil
                status = .scanning
            } else {
                clearHighlight(remember: true)
            }
        }
    }

    /// The object the head points at: of the plausible boxes near the frame center, the largest
    /// (a sleeve rather than the face printed on it).
    static func pickCandidate(_ boxes: [CGRect]) -> CGRect? {
        let ok = boxes.filter { box in
            let area = box.width * box.height
            let m = LookTuning.edgeMargin
            return area >= LookTuning.minBoxArea && area <= LookTuning.maxBoxArea
                && box.minX > m && box.minY > m && box.maxX < 1 - m && box.maxY < 1 - m
                && hypot(box.midX - 0.5, box.midY - 0.5) <= LookTuning.centerRadius
        }
        return ok.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Mostly inside the frame and not degenerate.
    private static func inView(_ box: CGRect) -> Bool {
        let visible = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !visible.isNull, box.width > 0.02, box.height > 0.02 else { return false }
        return visible.width * visible.height >= 0.5 * box.width * box.height
    }

    private func resetDwell() {
        dwellBox = nil
        dwellStart = 0
    }

    // MARK: Identify + price

    private func identify(_ frame: LookFrame, box: CGRect, now: TimeInterval) {
        identifying = true
        lastIdentifyStart = now
        trackedBox = box
        lastSeen = now
        identifyTask = Task {
            guard let crop = await vision.crop(frame, box: box, maxDimension: LookTuning.maxCropDimension) else {
                finishIdentify(shown: false)
                return
            }
            // 3. Seen this recently (shown, dismissed, or not a product): skip the network.
            if remembered(hash: crop.hash, box: box) {
                finishIdentify(shown: false)
                return
            }
            status = .identifying
            await vision.startTracking(box)
            do {
                let id = try await api.identifyLook(imageJPEG: crop.jpeg)
                guard !Task.isCancelled, isEnabled, identifying else { return }
                notice = nil
                let name = id.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !id.isProduct || id.confidence < LookTuning.minConfidence || name.isEmpty {
                    remember(.rejected, hash: crop.hash, box: box, name: nil, for: LookTuning.rejectMemory)
                    finishIdentify(shown: false)
                    return
                }
                if remembered(name: name) {
                    remember(.rejected, hash: crop.hash, box: box, name: nil, for: LookTuning.rejectMemory)
                    finishIdentify(shown: false)
                    return
                }
                show(id, box: trackedBox ?? box, hash: crop.hash)
                finishIdentify(shown: true)
            } catch {
                guard !Task.isCancelled else { return }
                // A 502 (the vision call failed) is just "no result". Either way back off like any
                // other miss; only an unreachable backend is worth telling the wearer about.
                remember(.rejected, hash: crop.hash, box: box, name: nil, for: LookTuning.identifyInterval * 2)
                finishIdentify(shown: false)
                if case APIError.transport = error { notice = "Can't reach DEAL" }
            }
        }
    }

    private func finishIdentify(shown: Bool) {
        identifying = false
        if !shown {
            vision.stopTracking()
            trackedBox = nil
            resetDwell()
            if isEnabled { status = .scanning }
        }
    }

    private func show(_ id: LookIdentification, box: CGRect, hash: UInt64) {
        let item = LookHighlight(id: UUID(), box: box, identification: id)
        highlight = item
        highlightLost = false
        highlightHash = hash
        page = .price
        priceError = nil
        research = nil
        researchError = nil
        researchLoading = false
        status = .showing
        Platform.haptic(.success)
        remember(.shown, hash: hash, box: box, name: id.name, for: LookTuning.shownMemory)
        pushGlasses()

        let name = id.name ?? ""
        priceTask = Task {
            do {
                let price = try await api.lookPrice(name: name, category: id.category)
                guard highlight?.id == item.id else { return }
                highlight?.price = price
                pushGlasses()
            } catch {
                guard highlight?.id == item.id else { return }
                priceError = "Price unavailable"
            }
        }
    }

    private func clearHighlight(remember shown: Bool) {
        priceTask?.cancel()
        researchTask?.cancel()
        if shown, let h = highlight {
            // "Already shown" counts from when it went away.
            remember(.shown, hash: highlightHash, box: h.box, name: h.identification.name, for: LookTuning.shownMemory)
        }
        let had = highlight != nil
        highlight = nil
        highlightLost = false
        highlightHash = nil
        trackedBox = nil
        research = nil
        researchLoading = false
        vision.stopTracking()
        resetDwell()
        if isEnabled { status = .scanning }
        if had { pushGlasses() }
    }

    // MARK: Memory

    private func remember(_ kind: Memory.Kind, hash: UInt64?, box: CGRect?, name: String?, for seconds: TimeInterval) {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        let key = name.map(Self.normalize)
        // Keep the longest suppression per name.
        if let key, let i = memory.firstIndex(where: { $0.name == key }) {
            if memory[i].kind == .dismissed && kind != .dismissed { return }
            memory[i] = Memory(kind: kind, hash: hash ?? memory[i].hash, box: box ?? memory[i].box, name: key, until: until)
            return
        }
        memory.append(Memory(kind: kind, hash: hash, box: box, name: key, until: until))
        if memory.count > 40 { memory.removeFirst(memory.count - 40) }
    }

    private func remembered(hash: UInt64, box: CGRect) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return memory.contains { m in
            guard m.until > now, let h = m.hash else { return false }
            let close = (h ^ hash).nonzeroBitCount <= LookTuning.hashMatchBits
            // A dismissed item stays quiet wherever it shows up; others only in about the same place.
            return close && (m.kind == .dismissed || (m.box.map { $0.iou(box) >= 0.3 } ?? true))
        }
    }

    private func remembered(name: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let key = Self.normalize(name)
        return memory.contains { $0.until > now && $0.name == key && $0.kind != .rejected }
    }

    private func pruneMemory(_ now: TimeInterval) {
        memory.removeAll { $0.until <= ProcessInfo.processInfo.systemUptime }
    }

    /// "The Weeknd – Starboy (2×LP vinyl)" and "the weeknd starboy 2xlp vinyl" are the same item.
    static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "×", with: "x")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Gestures

    /// Neural Band gestures and the on-screen buttons both land here.
    func handle(_ gesture: LookGesture) {
        guard highlight != nil else { return }
        Platform.haptic(.tap)
        switch gesture {
        case .select:
            highlight?.expanded.toggle()
            if highlight?.expanded == true { startResearchIfNeeded() }
        case .next, .previous:
            let all = DetailPage.allCases
            let step = gesture == .next ? 1 : all.count - 1
            if highlight?.expanded == false {
                highlight?.expanded = true
                startResearchIfNeeded()
            } else {
                page = all[(page.rawValue + step) % all.count]
            }
        case .dismiss:
            guard let h = highlight else { return }
            remember(.dismissed, hash: highlightHash, box: h.box, name: h.identification.name, for: LookTuning.dismissSuppression)
            clearHighlight(remember: false)
            return
        case .negotiate:
            if let h = highlight { onNegotiate?(h) }
            return
        }
        pushGlasses()
    }

    private func startResearchIfNeeded() {
        guard let h = highlight, research == nil, !researchLoading, let name = h.identification.name else { return }
        researchLoading = true
        researchError = nil
        let id = h.id
        let category = DealCategory(rawValue: h.identification.category ?? "") ?? .other
        researchTask = Task {
            do {
                let result = try await api.researchPreview(item: name, category: category, askingPrice: nil)
                guard highlight?.id == id else { return }
                research = result
            } catch {
                guard highlight?.id == id, !Task.isCancelled else { return }
                researchError = "Couldn't load sources"
            }
            if highlight?.id == id { researchLoading = false }
        }
    }

    // MARK: Glasses

    /// Sends the card only when what it shows changes (box moves don't count).
    private func pushGlasses() {
        let key = highlight.map { "\($0.id)|\($0.price?.summary ?? "")|\($0.expanded)|\(page.rawValue)" }
        guard key != glassesKey else { return }
        glassesKey = key
        onGlassesUpdate?(highlight)
    }
}

/// Look mode's gating thresholds, in one place.
enum LookTuning {
    /// Seconds the same centered object has to stay put before DEAL asks what it is.
    static let dwell: TimeInterval = 1.2
    /// Mean absolute luma change per frame (0…1, on a 24×24 thumbnail) that counts as a head turn.
    static let motionThreshold = 0.06
    /// Consecutive candidate boxes must overlap this much to keep the dwell going.
    static let stableIoU: CGFloat = 0.45
    /// Candidate boxes: share of the frame, distance from the edge, distance of the center from
    /// the frame center (the gaze proxy).
    static let minBoxArea: CGFloat = 0.02
    static let maxBoxArea: CGFloat = 0.7
    static let edgeMargin: CGFloat = 0.01
    static let centerRadius: CGFloat = 0.28
    /// `/look/identify` confidence needed to highlight.
    static let minConfidence = 0.6
    /// At most one identify every this many seconds.
    static let identifyInterval: TimeInterval = 2
    static let maxCropDimension: CGFloat = 768
    /// Tracker confidence below this means the item is out of view.
    static let trackConfidence: Float = 0.3
    /// Seconds after the item leaves view before the highlight clears (it fades meanwhile).
    static let lostFade: TimeInterval = 2
    /// Memory: dismissed (5 min), shown (1 min after it goes away), not a product (20 s).
    static let dismissSuppression: TimeInterval = 5 * 60
    static let shownMemory: TimeInterval = 60
    static let rejectMemory: TimeInterval = 20
    /// dHash bits that may differ for two crops to count as the same thing.
    static let hashMatchBits = 12
}
