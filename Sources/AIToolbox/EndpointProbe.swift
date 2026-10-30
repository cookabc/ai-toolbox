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

    /// Compact readout for the provider card, e.g. `HTTP 200 · 342 ms`.
    var summary: String {
        let time = L10n.Probe.latency(Format.milliseconds(latency))
        guard let status else { return time }
        return "\(L10n.Probe.status(status)) · \(time)"
    }

    /// The verdict in a word or two, shown before the readout so the outcome does
    /// not depend on reading a colour or knowing what a status code means.
    var verdictLabel: String {
        switch verdict {
        case .healthy: L10n.Probe.healthy
        case .needsAuth: L10n.Probe.needsAuth
        case .badRoute: L10n.Probe.badRoute
        case .unsupported: L10n.Probe.unsupported
        case .rejected: L10n.Probe.rejected
        case .unreachable: L10n.Probe.unreachable
        }
    }

    /// How serious the outcome is: fine, fixable on the user's side, or broken.
    enum Severity: Equatable, Sendable { case ok, caution, failure }

    var severity: Severity {
        switch verdict {
        case .healthy: .ok
        case .needsAuth, .rejected: .caution
        case .badRoute, .unsupported, .unreachable: .failure
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
                detail: L10n.Probe.unusableURL
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
                    detail: L10n.Probe.notHTTP
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
            explanation = L10n.Probe.healthyDetail
        case .needsAuth:
            explanation = L10n.Probe.needsAuthDetail
        case .badRoute:
            explanation = app == .claude ? L10n.Probe.badRouteClaude : L10n.Probe.badRouteCodex
        case .unsupported:
            explanation = L10n.Probe.unsupportedDetail(app.title)
        case .rejected:
            explanation = L10n.Probe.rejectedDetail
        case .unreachable:
            explanation = L10n.Probe.unreachableDetail
        }
        guard let server = serverMessage(in: body), !server.isEmpty else { return explanation }
        return L10n.Probe.withServerMessage(explanation, server)
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
        let collapsed =
            message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }

    private static func transportDetail(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .timedOut:
            return L10n.Probe.timedOut(Int(timeout))
        case .cannotFindHost, .dnsLookupFailed:
            return L10n.Probe.dnsFailed
        case .cannotConnectToHost:
            return L10n.Probe.cannotConnect
        case .notConnectedToInternet:
            return L10n.Probe.offline
        case .appTransportSecurityRequiresSecureConnection:
            return L10n.Probe.atsBlocked
        case .secureConnectionFailed, .serverCertificateUntrusted,
            .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return L10n.Probe.tlsFailed
        default:
            return urlError.localizedDescription
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
