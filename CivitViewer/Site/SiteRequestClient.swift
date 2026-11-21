import Foundation

@MainActor protocol SiteAuthorizedTransport {
    var hasCredentials: Bool { get }
    func authorizedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

@MainActor protocol SiteAnonymousTransport {
    var pageURL: URL? { get }
    var isLoading: Bool { get }
    func loadSessionIfNeeded()
    func evaluate(_ script: String, arguments: [String: Any]) async throws -> Any?
}

/// Executes site requests. The session decides whether their account context is still valid.
@MainActor struct SiteRequestClient {
    enum Response: Equatable, Sendable {
        case rest, rpc, identity
    }

    private let origin: String
    private let oauth: any SiteAuthorizedTransport
    private let web: any SiteAnonymousTransport
    private let cooldown: SiteRequestCooldown
    private let publicData: (URL) async throws -> (Data, URLResponse)
    private let waitForOrigin: () async throws -> Void

    init(origin: String, oauth: any SiteAuthorizedTransport, web: any SiteAnonymousTransport, cooldown: SiteRequestCooldown,
         publicData: @escaping (URL) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(from: $0) },
         waitForOrigin: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.origin = origin
        self.oauth = oauth
        self.web = web
        self.cooldown = cooldown
        self.publicData = publicData
        self.waitForOrigin = waitForOrigin
    }

    func request<T: Decodable & Sendable>(path: String, postBody: String? = nil, response: Response = .rest,
                               preferPublicREST: Bool = false, loginPresented: () -> Bool,
                               validateSession: () throws -> Void) async throws -> T {
        try validateSession()
        guard path.hasPrefix("/api/"), let url = URL(string: origin + path), let host = url.host else {
            throw ClientError.invalidResponse
        }
        let limitedRead = postBody == nil && response != .identity && !path.hasPrefix("/api/auth/")
        if limitedRead { try cooldown.check() }
        if oauth.hasCredentials {
            return try await authorized(url: url, postBody: postBody, response: response, limitedRead: limitedRead,
                                        validateSession: validateSession)
        }
        if preferPublicREST, limitedRead, response == .rest {
            let (data, response) = try await qualified(validateSession) { try await publicData(url) }
            guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
            if response.statusCode != 403 {
                try cooldown.validateResponse(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
                return try await qualified(validateSession) { try await SiteResponseDecoder.decode(T.self, data: data, mapped: false) }
            }
            // Some site edges require a browser. Fall back to the real site context once.
            return try await request(path: path, loginPresented: loginPresented, validateSession: validateSession)
        }
        return try await anonymous(path: path, host: host, postBody: postBody, response: response, limitedRead: limitedRead,
                                   loginPresented: loginPresented, validateSession: validateSession)
    }

    private func authorized<T: Decodable & Sendable>(url: URL, postBody: String?, response: Response, limitedRead: Bool,
                                         validateSession: () throws -> Void) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = postBody == nil ? "GET" : "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let postBody {
            request.httpBody = Data(postBody.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, http) = try await qualified(validateSession) { try await oauth.authorizedData(for: request) }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        try cooldown.validateResponse(status: http.statusCode, retryAfter: retryAfter, markSuccess: false)
        if response == .rest {
            let value = try await qualified(validateSession) { try await SiteResponseDecoder.decode(T.self, data: data) }
            if limitedRead { cooldown.recordSuccess() }
            return value
        }
        let envelope = try await qualified(validateSession) { try await SiteResponseDecoder.authorized(data, response: response) }
        if let status = envelope.failureStatus {
            try cooldown.validateResponse(status: status, retryAfter: retryAfter, markSuccess: false)
            throw ClientError.invalidResponse
        }
        guard let payload = envelope.payload else { throw ClientError.invalidResponse }
        if limitedRead { cooldown.recordSuccess() }
        return try await qualified(validateSession) { try await SiteResponseDecoder.decode(T.self, data: payload) }
    }

    private func anonymous<T: Decodable & Sendable>(path: String, host: String, postBody: String?, response: Response, limitedRead: Bool,
                                        loginPresented: () -> Bool, validateSession: () throws -> Void) async throws -> T {
        try await qualified(validateSession) {
            try await ensureOrigin(host: host, loginPresented: loginPresented())
        }
        let script = """
        if (location.origin !== origin) throw new Error('origin');
        const abort = new AbortController();
        const timer = setTimeout(() => abort.abort(), 25000);
        try {
          const options = {method, credentials:'include', cache:'no-store', signal:abort.signal};
          if (method === 'POST') { options.headers={'Content-Type':'application/json'}; options.body=body; }
          const r = await fetch(path, options);
          if (!r.ok) return JSON.stringify({ok:false,status:r.status,retryAfter:r.status===429?r.headers.get('Retry-After'):null});
          const value = await r.json();
          if (rpc && value.error) return JSON.stringify({ok:false,status:value.error.json?.data?.httpStatus || 400,retryAfter:r.headers.get('Retry-After')});
          let payload = rpc ? value.result?.data : value;
          if (rpc && payload && Object.prototype.hasOwnProperty.call(payload,'json')) payload = payload.json;
          if (identity) payload = payload?.user ? {id:payload.user.id,username:payload.user.username,browsingLevel:payload.user.browsingLevel ?? null,blurNsfw:payload.user.blurNsfw ?? null} : null;
          return JSON.stringify({ok:true,payload});
        } finally { clearTimeout(timer); }
        """
        let arguments: [String: Any] = [
            "origin": origin, "path": path, "method": postBody == nil ? "GET" : "POST",
            "body": postBody ?? "", "rpc": response == .rpc, "identity": response == .identity
        ]
        let result = try await qualified(validateSession) { try await web.evaluate(script, arguments: arguments) }
        guard let text = result as? String, let data = text.data(using: .utf8) else { throw ClientError.invalidResponse }
        let envelope = try await qualified(validateSession) { try await SiteResponseDecoder.anonymous(data) }
        if let status = envelope.failureStatus {
            try cooldown.validateResponse(status: status, retryAfter: envelope.retryAfter, markSuccess: false)
            throw ClientError.invalidResponse
        }
        guard let payload = envelope.payload else { throw ClientError.invalidResponse }
        if limitedRead { cooldown.recordSuccess() }
        return try await qualified(validateSession) { try await SiteResponseDecoder.decode(T.self, data: payload) }
    }

    private func ensureOrigin(host: String, loginPresented: Bool) async throws {
        guard !loginPresented else { throw ClientError.loadingSite }
        if web.pageURL?.host == host && !web.isLoading { return }
        web.loadSessionIfNeeded()
        for _ in 0..<80 {
            try Task.checkCancellation()
            if web.pageURL?.host == host && !web.isLoading { return }
            try await waitForOrigin()
        }
        throw ClientError.siteUnavailable
    }

    private func qualified<T>(_ validateSession: () throws -> Void, _ operation: () async throws -> T) async throws -> T {
        try validateSession()
        let result: T
        do { result = try await operation() }
        catch {
            try validateSession()
            throw error
        }
        try validateSession()
        return result
    }

}

/// Only owned bytes and Sendable values cross this boundary. Browser/session state stays on MainActor.
private enum SiteResponseDecoder {
    struct Envelope: Sendable {
        let payload: Data?
        var failureStatus: Int? = nil
        var retryAfter: String? = nil
    }

    @concurrent static func authorized(_ data: Data, response: SiteRequestClient.Response) async throws -> Envelope {
        try Task.checkCancellation()
        let payload: Any
        switch response {
        case .rest:
            return Envelope(payload: data)
        case .rpc:
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.invalidResponse }
            if let error = root["error"] {
                let root = error as? [String: Any] ?? [:]
                let value = root["json"] as? [String: Any] ?? root
                let status = (value["data"] as? [String: Any])?["httpStatus"] as? Int
                let effectiveStatus = status.flatMap { (100...599).contains($0) ? $0 : nil } ?? 400
                if effectiveStatus != 200 { return Envelope(payload: nil, failureStatus: effectiveStatus) }
            }
            guard let result = root["result"] as? [String: Any], let data = result["data"] else { throw ClientError.invalidResponse }
            payload = (data as? [String: Any])?["json"] ?? data
        case .identity:
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let user = root?["user"] as? [String: Any]
            payload = user.map { ["id": $0["id"] ?? NSNull(), "username": $0["username"] ?? NSNull(),
                                  "browsingLevel": $0["browsingLevel"] ?? NSNull(), "blurNsfw": $0["blurNsfw"] ?? NSNull()] } ?? NSNull()
        }
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        try Task.checkCancellation()
        return Envelope(payload: bytes)
    }

    @concurrent static func anonymous(_ data: Data) async throws -> Envelope {
        try Task.checkCancellation()
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.invalidResponse }
        guard envelope["ok"] as? Bool == true else {
            return Envelope(payload: nil, failureStatus: envelope["status"] as? Int ?? 500,
                            retryAfter: envelope["retryAfter"] as? String)
        }
        let bytes = try JSONSerialization.data(withJSONObject: envelope["payload"] ?? NSNull(), options: [.fragmentsAllowed])
        try Task.checkCancellation()
        return Envelope(payload: bytes)
    }

    @concurrent static func decode<T: Decodable & Sendable>(_ type: T.Type, data: Data, mapped: Bool = true) async throws -> T {
        try Task.checkCancellation()
        let value: T
        do { value = try JSONDecoder().decode(type, from: data) }
        catch DecodingError.typeMismatch(_, let c) where mapped { throw ClientError.format(c.codingPath.map(\.stringValue).joined(separator: ".")) }
        catch DecodingError.valueNotFound(_, let c) where mapped { throw ClientError.format(c.codingPath.map(\.stringValue).joined(separator: ".")) }
        catch DecodingError.keyNotFound(let key, let c) where mapped { throw ClientError.format((c.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")) }
        try Task.checkCancellation()
        return value
    }
}
