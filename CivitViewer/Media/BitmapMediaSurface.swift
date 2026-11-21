import SwiftUI
import UIKit
import Observation

/// Native bitmap playback. Only the focused page holds animation frames; grid
/// previews keep using a single still and never create animation/player fleets.
struct BitmapMediaSurface: View {
    let url: URL
    let active: Bool
    var gestureTopExclusion: CGFloat = 110
    var gestureExcludedFrames: [CGRect] = []
    var pausedForOverlay = false
    var warmCoverRequest: MediaPosterPolicy.CoverRequest? = nil
    var onReady: ((Bool) -> Void)? = nil
    var onVideoContent: (() -> Void)? = nil
    var onEdgeSwipe: MediaEdgeSwipeAction? = nil
    var onEdgeDrag: MediaEdgeDragAction? = nil
    var onDoubleTap: (() -> Void)? = nil
    @AppStorage("autoplay") private var autoplay = true
    @State private var resource: CachedImageResource?
    @State private var warmCover: WarmCover?
    @State private var frames: [UIImage] = []
    @State private var duration = 0.0
    @State private var failure: String?
    @State private var retry = 0
    @State private var playing = true
    private struct Key: Equatable { let url: URL; let retry: Int }
    private struct AnimationKey: Equatable { let file: URL?; let active: Bool }
    @State private var activeRequest: Key?
    @State private var activeAnimation: AnimationKey?

    private struct WarmCover {
        let request: MediaPosterPolicy.CoverRequest
        let generation: Int
        let pixels: UIImage
    }
    private struct WarmCoverLookupKey: Equatable {
        let request: MediaPosterPolicy.CoverRequest?
        let active: Bool
    }
    private var pendingCoverPixels: UIImage? {
        guard failure == nil, let warmCover, warmCover.request == warmCoverRequest,
              warmCover.request.source == url, warmCover.generation == MediaCache.shared.repairGeneration else { return nil }
        return warmCover.pixels
    }

    var body: some View {
        ZStack {
            if let pixels = resource?.preview ?? pendingCoverPixels {
                AnimatedBitmapView(preview: pixels, frames: resource == nil ? [] : frames, duration: duration,
                                   playing: active && playing && !pausedForOverlay)
                if let resource, resource.frameCount > 1 && active && !playing && failure == nil {
                    Image(systemName: "play.fill").font(.title).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(.black.opacity(0.35), in: Circle()).allowsHitTesting(false)
                }
            } else if failure == nil {
                VideoWaitingIndicator(visible: active && !pausedForOverlay)
            }
            if let failure {
                MediaLoadFailureContent(message: failure, retry: { retry += 1 })
                    .modifier(MediaFeedbackSurface())
            }
        }
        .task(id: WarmCoverLookupKey(request: warmCoverRequest, active: active)) {
            // A warm still is only display pixels. The original task continues
            // to own readiness, file leases, and animation.
            guard !Task.isCancelled, resource == nil, let request = warmCoverRequest,
                  request.source == url, !request.isVideo else { return }
            let cache = MediaCache.shared
            guard let pixels = cache.preparedCoverMemory(request) else { return }
            warmCover = WarmCover(request: request, generation: cache.repairGeneration, pixels: pixels)
        }
        .onReceive(MediaCache.shared.prefetchInvalidations) { generation in
            if let warmCover, warmCover.generation != generation { self.warmCover = nil }
        }
        .task(id: Key(url: url, retry: retry)) {
            let key = Key(url: url, retry: retry)
            guard !Task.isCancelled else { return }
            activeRequest = key
            resource = nil; frames = []; failure = nil; onReady?(false)
            do {
                #if DEBUG && targetEnvironment(simulator)
                try await TimelineCoverHandoffQA.holdOriginalIfNeeded(key.url)
                #endif
                let value = try await MediaCache.shared.imageResource(key.url)
                // The preview owns decoded pixels. Animation decoding takes
                // its own lease, so a parked still never pins a cache file.
                if let lease = value.lease { await MediaCache.shared.release(lease) }
                try Task.checkCancellation()
                guard activeRequest == key else { return }
                resource = CachedImageResource(file: value.file, preview: value.preview,
                                               frameCount: value.frameCount, lease: nil)
                warmCover = nil
                onReady?(true)
            } catch is CancellationError {} catch MediaDownloadError.videoContent {
                guard !Task.isCancelled, activeRequest == key else { return }; onVideoContent?()
            } catch {
                guard !Task.isCancelled, activeRequest == key else { return }
                failure = (error as? LocalizedError)?.errorDescription ?? "图片暂时无法加载"
            }
        }
        .task(id: AnimationKey(file: resource?.file, active: active)) {
            let key = AnimationKey(file: resource?.file, active: active)
            guard !Task.isCancelled else { return }
            activeAnimation = key
            frames = []; duration = 0
            guard key.active, let resource, resource.frameCount > 1, let file = key.file else { return }
            do {
                let animation = try await BitmapAnimationQueue.shared.load(file, source: url)
                try Task.checkCancellation()
                guard activeAnimation == key else { return }
                frames = animation.frames.map { UIImage(cgImage: $0) }; duration = animation.duration
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, activeAnimation == key else { return }
                failure = (error as? LocalizedError)?.errorDescription ?? "动图暂时无法播放"
            }
        }
        .onAppear { playing = autoplay }
        .onChange(of: active) { _, value in if value { playing = autoplay } }
        .onChange(of: autoplay) { _, value in playing = value }
        .background {
            MediaGestureLayer(active: active && !pausedForOverlay, isVideo: false, topExclusion: gestureTopExclusion, excludedFrames: gestureExcludedFrames, onEdgeSwipe: onEdgeSwipe,
                              onEdgeDrag: onEdgeDrag, onTap: (resource?.frameCount ?? 0) > 1 ? { playing.toggle() } : nil,
                              onDoubleTap: onDoubleTap)
        }
        .onDisappear { activeRequest = nil; activeAnimation = nil; frames = []; resource = nil; warmCover = nil; onReady?(false) }
    }
}

@MainActor private final class BitmapAnimationQueue {
    static let shared = BitmapAnimationQueue()
    private let queue = MediaLoadQueue(limit: 1, maximumWaiting: 2)
    func load(_ file: URL, source: URL) async throws -> MediaImageDecoder.Animation {
        let id = UUID(); try await queue.acquire(id); defer { queue.release(id) }
        let lease: MediaFileLease
        if let existing = await MediaCache.shared.leaseFile(file) { lease = existing }
        else {
            // A parked preview can outlive eviction. Resolve the source again
            // before starting a new file reader rather than trust its old URL.
            let replacement = try await MediaCache.shared.imageResource(source)
            guard let acquired = replacement.lease else { throw ImageLoadError.missingLocal }
            lease = acquired
        }
        do {
            try Task.checkCancellation()
            let job = Task.detached(priority: .userInitiated) { try MediaImageDecoder.animation(lease.file) }
            let value = try await withTaskCancellationHandler {
                let decoded = try await job.value; try Task.checkCancellation(); return decoded
            } onCancel: { job.cancel() }
            await MediaCache.shared.release(lease)
            return value
        } catch {
            // Cancellation awaits the actual detached reader before release.
            await MediaCache.shared.release(lease)
            throw error
        }
    }
}

private struct AnimatedBitmapView: UIViewRepresentable {
    let preview: UIImage
    let frames: [UIImage]
    let duration: Double
    let playing: Bool
    final class Host: UIView {
        let imageView = UIImageView()
        override init(frame: CGRect) { super.init(frame: frame); addSubview(imageView) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); imageView.frame = bounds }
    }
    func makeUIView(context: Context) -> Host {
        let host = Host(); let view = host.imageView; view.contentMode = .scaleAspectFit
        view.clipsToBounds = true; view.backgroundColor = .clear; view.isOpaque = false
        view.accessibilityIdentifier = "bitmap-media"
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return host
    }
    func updateUIView(_ host: Host, context: Context) {
        let view = host.imageView
        let changed = view.animationImages?.first !== frames.first || view.animationImages?.count != frames.count
        if changed {
            view.stopAnimating(); view.animationImages = frames.isEmpty ? nil : frames
            view.animationDuration = duration; view.animationRepeatCount = 0
        }
        view.image = preview
        if playing && !frames.isEmpty { if !view.isAnimating { view.startAnimating() } }
        else { view.stopAnimating() }
    }
    static func dismantleUIView(_ host: Host, coordinator: ()) {
        let view = host.imageView
        view.stopAnimating(); view.animationImages = nil; view.image = nil
    }
}

struct CoverPlaceholder: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var body: some View {
        Color.secondary.opacity(0.07)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: "，"))
    }
}

enum CachedPosterResourceIdentity: Equatable {
    case poster(source: URL, declared: URL?)
    case image(primary: URL, fallbackURLs: [URL])
}

@MainActor @Observable final class CachedPosterLoadResult {
    typealias Identity = CachedPosterResourceIdentity

    private(set) var identity: Identity?
    private(set) var image: UIImage?
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var stage: PosterDiagnosticStage?
    private var attempt: UInt64 = 0

    func image(for source: URL, declared: URL?) -> UIImage? {
        identity == .poster(source: source, declared: declared) ? image : nil
    }

    func image(for primary: URL, fallbackURLs: [URL]) -> UIImage? {
        identity == .image(primary: primary, fallbackURLs: fallbackURLs) ? image : nil
    }

    @discardableResult func begin(_ identity: Identity) -> UInt64 {
        attempt &+= 1
        if self.identity != identity { image = nil }
        self.identity = identity
        isLoading = true
        failed = false
        stage = .cachedPoster
        return attempt
    }

    func updateStage(_ stage: PosterDiagnosticStage, identity: Identity, attempt: UInt64) {
        guard self.identity == identity, self.attempt == attempt else { return }
        self.stage = stage
    }

    @discardableResult func succeed(_ image: UIImage, identity: Identity, attempt: UInt64) -> Bool {
        guard self.identity == identity, self.attempt == attempt else { return false }
        self.image = image
        isLoading = false
        failed = false
        return true
    }

    @discardableResult func fail(identity: Identity, attempt: UInt64) -> Bool {
        guard self.identity == identity, self.attempt == attempt else { return false }
        isLoading = false
        failed = image == nil
        return true
    }

    func cancel(identity: Identity, attempt: UInt64) {
        guard self.identity == identity, self.attempt == attempt else { return }
        isLoading = false
    }

    func clear() {
        attempt &+= 1
        identity = nil
        image = nil
        isLoading = false
        failed = false
        stage = nil
    }
}

struct CachedPoster: View {
    enum Presentation { case preview, imageOnly, hidden }

    let source: URL
    let declared: URL?
    var active = false
    var fit = false
    var presentation: Presentation = .preview
    var sharedResult: CachedPosterLoadResult? = nil
    var restoresDecodedCoverPreview = false
    var loadingEnabled = true
    var retryToken = 0
    var allowLocalExtraction = false
    var diagnosticWorkID: Int? = nil
    var onFailure: ((Bool) -> Void)? = nil
    var showsFailure = true
    var emptyPlaceholder: String? = nil
    var placeholderTitle: String? = nil
    var imageBlur: CGFloat = 0
    @State private var ownedResult = CachedPosterLoadResult()
    private var loadResult: CachedPosterLoadResult { sharedResult ?? ownedResult }
    private var resourceIdentity: CachedPosterLoadResult.Identity { .poster(source: source, declared: declared) }
    private var currentImage: UIImage? { loadResult.image(for: source, declared: declared) }
    private var hasCurrentImage: Bool { currentImage != nil }
    @State private var cacheRevision = 0
    #if DEBUG && targetEnvironment(simulator)
    @State private var qaRefreshing177: UUID?
    @State private var qaRefreshReleased177: UUID?
    #endif
    private struct Key: Equatable {
        let source: URL
        let declared: URL?
        let result: ObjectIdentifier
        let restoreDecodedPreview: Bool
        let local: Bool
        let retry: Int
        let workID: Int?
        let cacheRevision: Int
        let loadingEnabled: Bool
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if presentation != .hidden, let image = currentImage {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .blur(radius: imageBlur)
                } else if presentation == .preview {
                    CoverPlaceholder(symbol: "play.rectangle",
                        title: placeholderTitle ?? "视频预览",
                        detail: emptyPlaceholder)
                    .accessibilityLabel([placeholderTitle, emptyPlaceholder].compactMap { $0 }.joined(separator: "，").isEmpty
                        ? "视频预览"
                        : [placeholderTitle, emptyPlaceholder].compactMap { $0 }.joined(separator: "，"))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: Key(source: source, declared: declared, result: ObjectIdentifier(loadResult),
                      restoreDecodedPreview: restoresDecodedCoverPreview, local: allowLocalExtraction,
                      retry: retryToken, workID: diagnosticWorkID, cacheRevision: cacheRevision,
                      loadingEnabled: loadingEnabled)) {
            guard !Task.isCancelled else { return }
            guard loadingEnabled else { return }
            let identity = resourceIdentity
            let attempt = loadResult.begin(identity)
            #if DEBUG && targetEnvironment(simulator)
            let qaHadCurrentImage177 = hasCurrentImage
            #endif
            onFailure?(false)
            var stage = PosterDiagnosticStage.cachedPoster
            notePoster(.posterStarted, error: nil, stage: stage)
            do {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--qa-cover69-wait") { try await Task.sleep(for: .seconds(6)) }
                if ProcessInfo.processInfo.arguments.contains("--qa-cover69-cancel") { throw CancellationError() }
                if ProcessInfo.processInfo.arguments.contains("--qa-cover-refresh177"), cacheRevision > 0, qaHadCurrentImage177 {
                    let ticket = UUID()
                    qaRefreshing177 = ticket
                    defer { if qaRefreshing177 == ticket { qaRefreshing177 = nil } }
                    while qaRefreshReleased177 != ticket { try await Task.sleep(for: .milliseconds(50)) }
                }
                #endif
                // The focused native player supplies its current frame. A still
                // preview must not start a second original-video download.
                let value = try await MediaCache.shared.loadPoster(source: source, declared: declared, allowExtraction: false,
                    allowLocalExtraction: allowLocalExtraction, reusePreparedPreview: restoresDecodedCoverPreview,
                    onStage: { next in
                        stage = next; loadResult.updateStage(next, identity: identity, attempt: attempt)
                    })
                try Task.checkCancellation()
                guard loadResult.succeed(value, identity: identity, attempt: attempt) else { return }
                notePoster(.posterLoaded, error: nil, stage: stage)
            } catch is CancellationError {
                loadResult.cancel(identity: identity, attempt: attempt)
                if Task.isCancelled {
                    notePoster(.posterCancelled, error: nil, stage: stage)
                    return
                }
                if !loadResult.fail(identity: identity, attempt: attempt) { return }
                if hasCurrentImage { return }
                onFailure?(true)
                notePoster(.posterFailed, error: CancellationError(), stage: stage)
            } catch {
                loadResult.cancel(identity: identity, attempt: attempt)
                if Task.isCancelled { notePoster(.posterCancelled, error: nil, stage: stage); return }
                if !loadResult.fail(identity: identity, attempt: attempt) { return }
                if hasCurrentImage { return }
                onFailure?(true)
                notePoster(.posterFailed, error: error, stage: stage)
            }
        }
        .onReceive(MediaCache.shared.posterUpdates) { key in
            guard key == MediaCache.shared.posterCacheKey(for: source) else { return }
            cacheRevision += 1
        }
        .onDisappear { if sharedResult == nil { ownedResult.clear() } }
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if CollectionPagingQA.enabled, let diagnosticWorkID {
                let value = "state=\(hasCurrentImage ? "ready" : (loadResult.failed ? "failed" : "pending"));width=\(Int(currentImage?.size.width ?? 0));height=\(Int(currentImage?.size.height ?? 0));refreshing177=\(qaRefreshing177 != nil)"
                Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("poster.qa.\(diagnosticWorkID)").accessibilityValue(value)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if ProcessInfo.processInfo.arguments.contains("--qa-cover-refresh177"), let ticket = qaRefreshing177, let diagnosticWorkID {
                Button("完成刷新") { qaRefreshReleased177 = ticket }
                    .font(.caption2).buttonStyle(.bordered)
                    .accessibilityIdentifier("poster.qa.release177.\(diagnosticWorkID)")
            }
        }
        #endif
    }
    private func notePoster(_ code: DiagnosticCode, error: Error?, stage: PosterDiagnosticStage) {
        let status: Int?
        if case .http(let value)? = error as? MediaDownloadError { status = value } else { status = nil }
        let context = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: source.isFileURL ? .local : .network,
            requestedURL: declared ?? source, sourceURL: source, recoveryAttempted: retryToken > 0,
            error: error.map { $0 as NSError }, eventStatusCodes: status.map { [$0] } ?? [],
            posterStage: stage, posterFailure: error.map { PosterDiagnosticPolicy.failure($0, stage: stage) })
        guard let context else { return }
        LocalDiagnosticsStore.shared.note(area: .thumbnail, code: code, httpStatus: status, playback: context)
    }
}
