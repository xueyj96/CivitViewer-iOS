import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor final class BoundaryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

struct BoundaryPayload: Decodable, Equatable { let value: Int }

@MainActor final class BoundaryOAuth: SiteAuthorizedTransport {
    var hasCredentials = true
    var calls = 0
    var authorized: (URLRequest) async throws -> (Data, HTTPURLResponse) = { _ in
        (Data(#"{"value":1}"#.utf8), HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func authorizedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        return try await authorized(request)
    }
}

@MainActor final class BoundaryWebView: SiteAnonymousTransport {
    var pageURL: URL? = URL(string: "https://example.invalid/")
    var isLoading = false
    var loads = 0
    var javascriptCalls = 0
    var onLoad: () -> Void = {}
    var javascript: (String, [String: Any]) async throws -> Any = { _, _ in
        #"{"ok":true,"payload":{"value":1}}"#
    }
    let javascriptStarted = BoundaryGate()

    func loadSessionIfNeeded() { loads += 1; onLoad() }
    func evaluate(_ script: String, arguments: [String: Any]) async throws -> Any? {
        javascriptCalls += 1
        javascriptStarted.open()
        return try await javascript(script, arguments)
    }
}

@MainActor final class BoundaryPublicRead {
    var calls = 0
    var load: (URL) async throws -> (Data, URLResponse) = { _ in throw URLError(.resourceUnavailable) }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        calls += 1
        return try await load(url)
    }
}

@MainActor final class SessionBoundaryHarness {
    static let origin = "https://example.invalid"
    var account: Account? = Account(id: 42, username: "fixture", browsingLevel: 1, blurNsfw: true)
    var authGeneration = 7
    var showLogin = false
    let oauth = BoundaryOAuth()
    let webView = BoundaryWebView()
    let publicRead = BoundaryPublicRead()
    let cooldown = SiteRequestCooldown()
    let requestClient: SiteRequestClient

    init() {
        requestClient = SiteRequestClient(origin: Self.origin, oauth: oauth, web: webView, cooldown: cooldown,
                                        publicData: publicRead.data(from:),
                                        waitForOrigin: { try await Task.sleep(for: .milliseconds(1)) })
    }

    // Exercise the production session adapter and its batch-query caller.
    // INSERT_EXTRACTED_FEED_IDENTITY
    // INSERT_EXTRACTED_REQUEST
    // INSERT_EXTRACTED_HYDRATE_MEDIA
}

@main struct SessionBoundaryChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        func response(_ status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.invalid/api/fixture")!, statusCode: status,
                            httpVersion: nil, headerFields: nil)!
        }
        func payload(_ value: Int = 1) -> Data { Data(#"{"value":\#(value)}"#.utf8) }

        // Old OAuth success cannot cross an epoch change when account and mask are unchanged.
        let oauthSuccess = SessionBoundaryHarness(), oauthSuccessGate = BoundaryGate()
        let originalAccount = oauthSuccess.account, originalIdentity = oauthSuccess.feedIdentity
        oauthSuccess.oauth.authorized = { _ in await oauthSuccessGate.wait(); return (payload(), response()) }
        let oldSuccess = Task { try await oauthSuccess.request(path: "/api/fixture") as BoundaryPayload }
        while oauthSuccess.oauth.calls == 0 { await Task.yield() }
        oauthSuccess.authGeneration += 1
        check(oauthSuccess.account == originalAccount && oauthSuccess.feedIdentity != originalIdentity,
              "Epoch change changes identity while preserving account and browsing mask")
        oauthSuccessGate.open()
        do { _ = try await oldSuccess.value; check(false, "Old OAuth success must be cancelled") }
        catch is CancellationError { check(true, "Old OAuth success is cancelled after epoch change") }

        // The same boundary also takes precedence over an old transport error.
        let oauthFailure = SessionBoundaryHarness(), oauthFailureGate = BoundaryGate()
        oauthFailure.oauth.authorized = { _ in await oauthFailureGate.wait(); throw URLError(.timedOut) }
        let oldFailure = Task { try await oauthFailure.request(path: "/api/fixture") as BoundaryPayload }
        while oauthFailure.oauth.calls == 0 { await Task.yield() }
        oauthFailure.authGeneration += 1; oauthFailureGate.open()
        do { _ = try await oldFailure.value; check(false, "Old OAuth failure must be cancelled") }
        catch is CancellationError { check(true, "Epoch invalidation takes precedence over old OAuth transport error") }

        // A same-account request in a new epoch may complete, and ordinary token rotation leaves epoch intact.
        let newEpoch = SessionBoundaryHarness(), identityBefore = newEpoch.feedIdentity
        newEpoch.authGeneration += 1
        let newIdentity = newEpoch.feedIdentity
        let newEpochResult: BoundaryPayload = try await newEpoch.request(path: "/api/fixture")
        check(identityBefore != newIdentity && newEpochResult == BoundaryPayload(value: 1),
              "Same-account new-epoch identity can make a fresh request")
        let tokenRefresh = SessionBoundaryHarness(), tokenIdentity = tokenRefresh.feedIdentity
        tokenRefresh.oauth.authorized = { _ in (payload(2), response()) }
        let tokenResult: BoundaryPayload = try await tokenRefresh.request(path: "/api/fixture")
        check(tokenRefresh.feedIdentity == tokenIdentity && tokenResult == BoundaryPayload(value: 2),
              "Token refresh without epoch change remains a normal successful request")

        let media = SessionBoundaryHarness()
        var mediaQueries: [[URLQueryItem]] = []
        media.oauth.authorized = { request in
            check(request.httpMethod == "GET" && request.url?.path == "/api/v1/images", "Batch hydration uses the media REST read")
            mediaQueries.append(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? [])
            return (Data(#"{"items":[{"id":101,"url":"https://example.invalid/video.mp4","type":"video","postId":5,"tags":[{"id":7,"name":"portrait"}],"metadata":{"duration":23.5}}],"metadata":{"nextCursor":"page-2"}}"#.utf8), response())
        }
        let mediaPage = try await media.hydrateMedia(ids: [404, 101], browsingLevel: 31, includeTags: true)
        check(mediaPage.items.map(\.id) == [101] && mediaPage.items.first?.durationSeconds == 23.5
              && mediaPage.items.first?.tags?.first?.id == 7 && mediaPage.metadata.nextCursor == "page-2",
              "Direct REST decoding preserves the items, tags, technical metadata and cursor")
        _ = try await media.hydrateMedia(ids: [101], browsingLevel: 1, includeTags: false)
        check(mediaQueries == [
            [.init(name: "ids", value: "404,101"), .init(name: "limit", value: "2"),
             .init(name: "browsingLevel", value: "31"), .init(name: "withTags", value: "true")],
            [.init(name: "ids", value: "101"), .init(name: "limit", value: "1"),
             .init(name: "browsingLevel", value: "1")]
        ], "Batch hydration keeps ID order and the caller's level, and requests tags only when needed")

        let rpc = SessionBoundaryHarness()
        rpc.oauth.authorized = { _ in (Data(#"{"result":{"data":{"json":{"value":9}}}}"#.utf8), response()) }
        let rpcResult: BoundaryPayload = try await rpc.request(path: "/api/trpc/fixture", response: .rpc)
        check(rpcResult.value == 9, "tRPC retains its envelope decoding")

        let session = SessionBoundaryHarness()
        session.oauth.authorized = { _ in (Data(#"{"user":{"id":42,"username":"fixture","browsingLevel":1}}"#.utf8), response()) }
        let identity: Account? = try await session.request(path: "/api/auth/session", response: .identity)
        check(identity?.id == 42 && identity?.browsingLevel == 1, "Account identity retains its session envelope projection")

        // A cancelled entry is rejected before either transport can begin.
        let cancelledEntry = SessionBoundaryHarness()
        let cancelledTask = Task {
            await Task.yield()
            return try await cancelledEntry.request(path: "/api/fixture") as BoundaryPayload
        }
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; check(false, "Cancelled request entry must throw") }
        catch is CancellationError { check(cancelledEntry.oauth.calls == 0 && cancelledEntry.webView.javascriptCalls == 0,
                                            "Cancelled entry starts no OAuth or WebKit transport") }

        // WebKit success and failure after a suspended JavaScript call are both fenced.
        for shouldThrow in [false, true] {
            let web = SessionBoundaryHarness(), javascriptGate = BoundaryGate()
            web.oauth.hasCredentials = false
            web.webView.javascript = { _, _ in
                await javascriptGate.wait()
                if shouldThrow { throw URLError(.timedOut) }
                return #"{"ok":true,"payload":{"value":3}}"#
            }
            let call = Task { try await web.request(path: "/api/fixture") as BoundaryPayload }
            await web.webView.javascriptStarted.wait()
            web.authGeneration += 1; javascriptGate.open()
            do { _ = try await call.value; check(false, "WebKit result after epoch change must be cancelled") }
            catch is CancellationError { check(web.webView.javascriptCalls == 1,
                                                "WebKit success/error after epoch change is cancelled") }
        }

        // ensureOrigin success after navigation is fenced before JavaScript starts.
        let originSuccess = SessionBoundaryHarness(), originLoad = BoundaryGate()
        originSuccess.oauth.hasCredentials = false
        originSuccess.webView.pageURL = URL(string: "https://unrelated.invalid/")
        originSuccess.webView.onLoad = {
            originLoad.open()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(5))
                originSuccess.webView.pageURL = URL(string: "https://example.invalid/")
            }
        }
        let originSuccessTask = Task { try await originSuccess.request(path: "/api/fixture") as BoundaryPayload }
        await originLoad.wait(); originSuccess.authGeneration += 1
        do { _ = try await originSuccessTask.value; check(false, "ensureOrigin success after epoch change must be cancelled") }
        catch is CancellationError { check(originSuccess.webView.loads == 1 && originSuccess.webView.javascriptCalls == 0,
                                            "ensureOrigin success is followed by an epoch check before WebKit request") }

        // ensureOrigin exhaustion is also followed by the request epoch check.
        let originFailure = SessionBoundaryHarness(), failedLoad = BoundaryGate()
        originFailure.oauth.hasCredentials = false
        originFailure.webView.pageURL = URL(string: "https://unrelated.invalid/")
        originFailure.webView.onLoad = { failedLoad.open() }
        let originFailureTask = Task { try await originFailure.request(path: "/api/fixture") as BoundaryPayload }
        await failedLoad.wait(); originFailure.authGeneration += 1
        do { _ = try await originFailureTask.value; check(false, "ensureOrigin failure after epoch change must be cancelled") }
        catch is CancellationError { check(originFailure.webView.loads == 1 && originFailure.webView.javascriptCalls == 0,
                                            "ensureOrigin failure is replaced by cancellation for a stale epoch") }

        // Current-epoch HTTP/JSON failures keep their existing error scope.
        let http = SessionBoundaryHarness()
        http.oauth.authorized = { _ in (payload(), response(429)) }
        do { let _: BoundaryPayload = try await http.request(path: "/api/fixture"); check(false, "HTTP failure expected") }
        catch ClientError.http(let status) { check(status == 429, "Current-epoch HTTP status remains ClientError.http") }
        do { let _: BoundaryPayload = try await http.request(path: "/api/fixture"); check(false, "Cooldown expected") }
        catch ClientError.http(let status) { check(status == 429 && http.oauth.calls == 1, "Cooldown blocks a second request before transport") }
        let json = SessionBoundaryHarness()
        json.oauth.authorized = { _ in (Data("not-json".utf8), response()) }
        do { let _: BoundaryPayload = try await json.request(path: "/api/fixture"); check(false, "JSON failure expected") }
        catch is ClientError { check(false, "Raw JSON parser error is not rewritten as ClientError") }
        catch { check(true, "Current-epoch malformed JSON preserves the parser error") }
        let webHTTP = SessionBoundaryHarness()
        webHTTP.oauth.hasCredentials = false
        webHTTP.webView.javascript = { _, _ in #"{"ok":false,"status":429}"# }
        do { let _: BoundaryPayload = try await webHTTP.request(path: "/api/fixture"); check(false, "WebKit HTTP failure expected") }
        catch ClientError.http(let status) { check(status == 429, "WebKit HTTP status retains ClientError.http mapping") }

        let direct = SessionBoundaryHarness()
        direct.oauth.hasCredentials = false
        direct.publicRead.load = { _ in (payload(4), response()) }
        let directResult: BoundaryPayload = try await direct.request(path: "/api/v1/images", preferPublicREST: true)
        check(directResult.value == 4 && direct.publicRead.calls == 1 && direct.webView.javascriptCalls == 0,
              "Anonymous public media prefers the direct request")
        direct.publicRead.load = { url in
            check(url.absoluteString == "https://example.invalid/api/v1/images?cursor=a%2Fb",
                  "Public REST retains the percent-encoded query")
            return (Data(), response(403))
        }
        direct.webView.javascript = { _, args in
            check(args["path"] as? String == "/api/v1/images?cursor=a%2Fb" && args["method"] as? String == "GET",
                  "The browser fallback preserves the encoded path and method")
            return #"{"ok":true,"payload":{"value":6}}"#
        }
        let fallback: BoundaryPayload = try await direct.request(path: "/api/v1/images?cursor=a%2Fb", preferPublicREST: true)
        check(fallback.value == 6 && direct.publicRead.calls == 2 && direct.webView.javascriptCalls == 1,
              "An anonymous public 403 falls back once to the browser")

        for status in [403, 429] {
            let stale = SessionBoundaryHarness(), started = BoundaryGate(), release = BoundaryGate()
            stale.oauth.hasCredentials = false
            stale.publicRead.load = { _ in
                started.open()
                await release.wait()
                return (Data(), response(status))
            }
            let read = Task { try await stale.request(path: "/api/v1/images", preferPublicREST: true) as BoundaryPayload }
            await started.wait()
            stale.authGeneration += 1
            release.open()
            do { _ = try await read.value; check(false, "An old public response must be cancelled") }
            catch is CancellationError {
                check(stale.webView.javascriptCalls == 0 && stale.cooldown.retryAvailableAt == nil,
                      "A stale public 403 or 429 cannot trigger fallback or change cooldown")
            }
        }

        let login = SessionBoundaryHarness()
        login.oauth.hasCredentials = false
        login.showLogin = true
        do { let _: BoundaryPayload = try await login.request(path: "/api/fixture"); check(false, "Expected the login gate") }
        catch ClientError.loadingSite {
            check(login.webView.loads == 0 && login.webView.javascriptCalls == 0,
                  "The login sheet blocks anonymous WebKit work")
        }

        let mutation = SessionBoundaryHarness()
        mutation.cooldown.record429(retryAfter: "120")
        mutation.oauth.authorized = { request in
            check(request.httpMethod == "POST" && request.httpBody == Data("{}".utf8) &&
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json",
                  "A mutation keeps its method, body, and content type")
            return (Data(#"{"result":{"data":{"value":7}}}"#.utf8), response())
        }
        let written: BoundaryPayload = try await mutation.request(path: "/api/trpc/fixture", postBody: "{}", response: .rpc)
        check(written.value == 7 && mutation.cooldown.retryAvailableAt != nil,
              "A mutation bypasses the read gate without clearing cooldown")

        print("SessionBoundaryChecks: \(checks) regression checks passed")
    }
}
