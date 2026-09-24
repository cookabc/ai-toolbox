import Foundation

/// The outcome of one on-demand reachability check against a saved provider.
///
/// This exists because of a failure that is genuinely hard to read from the
/// outside: when a gateway does not answer the route the CLI actually calls,
/// Claude Code prints *"There's an issue with the selected model"* and sends you
/// hunting for a model problem that does not exist. Probing reports the real
/// HTTP status instead, and the verdict names the likely cause.
struct EndpointProbeResult: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        /// 2xx — the route answered.
        case healthy
        /// 401/403 — the route exists; the credential is what is wrong.
        case needsAuth
        /// 404 — the path the CLI would call is not there.
        case badRoute
        /// 405/501 — the gateway does not serve this protocol on any path.
        case unsupported
        /// Any other 4xx/5xx, including a model the endpoint does not know.
        case rejected
        /// Transport failure, timeout, or a base URL we could not turn into a request.
        case unreachable
    }

    var verdict: Verdict
    var status: Int?
    var latency: TimeInterval
    /// One sentence naming the likely cause, with the server's own message when
    /// it sent one. This is the part worth reading on a failure.
    var detail: String

    var isHealthy: Bool { verdict == .healthy }

    /// Compact label for the provider card, e.g. `200 · 342 ms`.
    var summary: String {
        let time = String(format: "%.0f ms", latency * 1000)
        guard let status else { return time }
        return "\(status) · \(time)"
    }

    var symbolName: String {
        switch verdict {
        case .healthy: "checkmark.circle.fill"
        case .needsAuth, .rejected: "exclamationmark.circle.fill"
        case .badRoute, .unsupported, .unreachable: "xmark.circle.fill"
        }
    }
}

enum EndpointProbe {
    /// Long enough for a slow gateway, short enough that the panel does not feel hung.
    static let timeout: TimeInterval = 12

    // MARK: - Building the request

    /// The URL each CLI builds for itself, so the probe tests what a real request
    /// would hit rather than what the panel happens to display.
    ///
    /// Claude Code appends `/v1/messages` to `ANTHROPIC_BASE_URL` on its own, which
    /// is why the stored value is normalised to the host root first — probing the
    /// raw stored value would reproduce the `…/v1/v1/messages` bug instead of
    /// detecting it. Codex is written with `wire_api = "responses"`, so it posts to
    /// `<base_url>/responses`.
    static func requestURL(app: LiveConfigApp, baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let root: String
        let endpointPath: String
        switch app {
        case .claude:
            root = ClaudeLiveSettingsStore.normalizedBaseURL(trimmed)
            endpointPath = "/v1/messages"
        case .codex:
            var value = trimmed
            while value.hasSuffix("/") { value.removeLast() }
            root = value
            endpointPath = "/responses"
        }
        guard !root.isEmpty, var components = URLComponents(string: root) else { return nil }

        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + endpointPath
        return components.url
    }

    /// A deliberately tiny request. `max_tokens: 1` keeps a successful probe from
    /// costing anything meaningful, and the model is omitted when the provider has
    /// none so the gateway still answers with a status we can classify.
    static func makeRequest(for provider: StoredProvider) -> URLRequest? {
        guard let url = requestURL(app: provider.app, baseURL: provider.baseURL) else { return nil }
        let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any]
        switch provider.app {
        case .claude:
            // The same header Claude Code sends for the provider's credential style.
            if !key.isEmpty {
                switch provider.credential {
                case .apiKey: request.setValue(key, forHTTPHeaderField: "x-api-key")
                case .authToken: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                }
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ]
        case .codex:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = ["input": "ping", "max_output_tokens": 16]
        }
        if !model.isEmpty { body["model"] = model }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Classifying the answer

    static func verdict(for status: Int) -> EndpointProbeResult.Verdict {
        switch status {
        case 200..<300: .healthy
        case 401, 403: .needsAuth
        case 404: .badRoute
        case 405, 501: .unsupported
        default: .rejected
        }
    }

    // MARK: - Probing

    /// Never routed through `CachedTranscriptProvider`: a reachability check is
    /// only meaningful if it actually goes out to the network.
    static func probe(_ provider: StoredProvider) async -> EndpointProbeResult {
        guard let request = makeRequest(for: provider) else {
            return EndpointProbeResult(
                verdict: .unreachable,
                status: nil,
                latency: 0,
                detail: "Base URL 无法解析成可请求的 http/https 地址。"
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        // A session keeps its connection pool and delegate queue until invalidated.
        defer { session.finishTasksAndInvalidate() }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await session.data(for: request)
            let latency = seconds(clock.now - start)
            guard let http = response as? HTTPURLResponse else {
                return EndpointProbeResult(
                    verdict: .unreachable,
                    status: nil,
                    latency: latency,
                    detail: "响应不是 HTTP 响应。"
                )
            }
            return EndpointProbeResult(
                verdict: verdict(for: http.statusCode),
                status: http.statusCode,
                latency: latency,
                detail: describe(status: http.statusCode, app: provider.app, body: data)
            )
        } catch {
            return EndpointProbeResult(
                verdict: .unreachable,
                status: nil,
                latency: seconds(clock.now - start),
                detail: transportDetail(error)
            )
        }
    }

    // MARK: - Messages

    private static func describe(status: Int, app: LiveConfigApp, body: Data) -> String {
        let explanation: String
        switch verdict(for: status) {
        case .healthy:
            explanation = "端点可达，路由与凭据都正常。"
        case .needsAuth:
            explanation = "路由存在，但凭据被拒绝——检查 API Key。"
        case .badRoute:
            explanation = app == .claude
                ? "路由不存在。Claude Code 会把这个 404 报成「模型不可用」。确认 Base URL 没有多余的 /v1。"
                : "路由不存在。Codex 按 wire_api = \"responses\" 请求 <Base URL>/responses。"
        case .unsupported:
            explanation = "网关不接受这个协议的请求，该供应商无法用于 \(app.title)。"
        case .rejected:
            explanation = "网关拒绝了请求。"
        case .unreachable:
            explanation = "无法连接。"
        }
        guard let server = serverMessage(in: body), !server.isEmpty else { return explanation }
        return "\(explanation) 服务端：\(server)"
    }

    /// Pulls the human-readable error out of the usual shapes:
    /// `{"error": {"message": …}}`, `{"error": "…"}`, `{"message": "…"}`.
    private static func serverMessage(in body: Data) -> String? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }

        var message: String?
        if let error = object["error"] as? [String: Any] {
            message = error["message"] as? String
        } else if let error = object["error"] as? String {
            message = error
        } else if let direct = object["message"] as? String {
            message = direct
        }
        guard let message else { return nil }
        let collapsed = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }

    private static func transportDetail(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .timedOut:
            return "请求超时（\(Int(timeout)) 秒内没有响应）。"
        case .cannotFindHost, .dnsLookupFailed:
            return "域名解析失败，检查主机名。"
        case .cannotConnectToHost:
            return "无法建立连接，检查地址与端口。"
        case .notConnectedToInternet:
            return "当前没有网络连接。"
        case .appTransportSecurityRequiresSecureConnection:
            return "系统策略阻止了明文 HTTP 请求。"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "TLS 握手失败或证书不受信任。"
        default:
            return urlError.localizedDescription
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
