import Foundation
import XCTest
@testable import AIToolbox

final class EndpointProbeTests: XCTestCase {
    // MARK: - URL building

    /// The regression guard for the bug this whole probe exists to catch: a provider
    /// stored the OpenAI way (`…/v1`, because Codex needs it) must be probed at
    /// `…/v1/messages`, not `…/v1/v1/messages`.
    func testClaudeProbeURLTargetsTheRouteClaudeCodeCalls() {
        let url = EndpointProbe.requestURL(app: .claude, baseURL: "https://relay.example/v1")
        XCTAssertEqual(url?.absoluteString, "https://relay.example/v1/messages")
    }

    func testClaudeProbeURLAcceptsHostRootAsStored() {
        let url = EndpointProbe.requestURL(app: .claude, baseURL: "https://relay.example")
        XCTAssertEqual(url?.absoluteString, "https://relay.example/v1/messages")
    }

    /// Codex is written with `wire_api = "responses"`, so the `/v1` stays and
    /// `/responses` is appended.
    func testCodexProbeURLTargetsResponsesRoute() {
        let url = EndpointProbe.requestURL(app: .codex, baseURL: "https://relay.example/v1")
        XCTAssertEqual(url?.absoluteString, "https://relay.example/v1/responses")
    }

    func testProbeURLKeepsGatewayPathPrefix() {
        XCTAssertEqual(
            EndpointProbe.requestURL(app: .claude, baseURL: "https://host.example/gateway/v1")?.absoluteString,
            "https://host.example/gateway/v1/messages"
        )
        XCTAssertEqual(
            EndpointProbe.requestURL(app: .codex, baseURL: "https://host.example/gateway/v1")?.absoluteString,
            "https://host.example/gateway/v1/responses"
        )
    }

    func testProbeURLToleratesTrailingSlash() {
        XCTAssertEqual(
            EndpointProbe.requestURL(app: .claude, baseURL: "https://host.example/v1/")?.absoluteString,
            "https://host.example/v1/messages"
        )
        XCTAssertEqual(
            EndpointProbe.requestURL(app: .codex, baseURL: "https://host.example/v1///")?.absoluteString,
            "https://host.example/v1/responses"
        )
    }

    /// Plain-HTTP LAN relays must still be probeable; anything that is not an
    /// absolute http(s) URL is refused rather than guessed at.
    func testProbeURLAllowsPlainHTTPButRejectsOtherSchemes() {
        XCTAssertEqual(
            EndpointProbe.requestURL(app: .claude, baseURL: "http://192.168.1.9:8080/v1")?.absoluteString,
            "http://192.168.1.9:8080/v1/messages"
        )
        XCTAssertNil(EndpointProbe.requestURL(app: .claude, baseURL: ""))
        XCTAssertNil(EndpointProbe.requestURL(app: .claude, baseURL: "   "))
        XCTAssertNil(EndpointProbe.requestURL(app: .claude, baseURL: "relay.example/v1"))
        XCTAssertNil(EndpointProbe.requestURL(app: .claude, baseURL: "ftp://relay.example/v1"))
    }

    // MARK: - Classification

    func testVerdictClassification() {
        XCTAssertEqual(EndpointProbe.verdict(for: 200), .healthy)
        XCTAssertEqual(EndpointProbe.verdict(for: 204), .healthy)
        XCTAssertEqual(EndpointProbe.verdict(for: 401), .needsAuth)
        XCTAssertEqual(EndpointProbe.verdict(for: 403), .needsAuth)
        XCTAssertEqual(EndpointProbe.verdict(for: 404), .badRoute)
        XCTAssertEqual(EndpointProbe.verdict(for: 405), .unsupported)
        XCTAssertEqual(EndpointProbe.verdict(for: 501), .unsupported)
        XCTAssertEqual(EndpointProbe.verdict(for: 400), .rejected)
        XCTAssertEqual(EndpointProbe.verdict(for: 429), .rejected)
        XCTAssertEqual(EndpointProbe.verdict(for: 500), .rejected)
    }

    func testSummaryReadsStatusThenLatency() {
        let result = EndpointProbeResult(verdict: .healthy, status: 200, latency: 0.342, detail: "")
        XCTAssertEqual(result.summary, "200 · 342 ms")
        XCTAssertTrue(result.isHealthy)
    }

    func testSummaryOmitsStatusWhenNothingAnswered() {
        let result = EndpointProbeResult(verdict: .unreachable, status: nil, latency: 12.0, detail: "")
        XCTAssertEqual(result.summary, "12000 ms")
        XCTAssertFalse(result.isHealthy)
    }

    // MARK: - Request shape

    func testClaudeProbeRequestUsesAnthropicHeaders() throws {
        let provider = StoredProvider(
            app: .claude, name: "Relay", slug: "relay",
            baseURL: "https://relay.example/v1", model: "claude-sonnet-4", apiKey: "sk-ant-x"
        )
        let request = try XCTUnwrap(EndpointProbe.makeRequest(for: provider))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/messages")
        XCTAssertEqual(request.timeoutInterval, EndpointProbe.timeout)

        let body = try body(of: request)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4")
        // One token, so a successful probe is effectively free.
        XCTAssertEqual(body["max_tokens"] as? Int, 1)
        XCTAssertNotNil(body["messages"])
    }

    /// Relays that only take `Authorization: Bearer` get what Claude Code sends for
    /// `ANTHROPIC_AUTH_TOKEN`, so the probe tests the same thing.
    func testClaudeAuthTokenProbeSendsBearer() throws {
        let provider = StoredProvider(app: .claude, name: "R", slug: "r", baseURL: "https://relay.test",
                                      model: "m", apiKey: "sk-token", credential: .authToken)
        let request = try XCTUnwrap(EndpointProbe.makeRequest(for: provider))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testCodexProbeRequestUsesBearerAuth() throws {
        let provider = StoredProvider(
            app: .codex, name: "Relay", slug: "relay",
            baseURL: "https://relay.example/v1", model: "gpt-5", apiKey: "sk-x"
        )
        let request = try XCTUnwrap(EndpointProbe.makeRequest(for: provider))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-x")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/responses")

        let body = try body(of: request)
        XCTAssertEqual(body["model"] as? String, "gpt-5")
        XCTAssertEqual(body["input"] as? String, "ping")
    }

    /// A provider with no model set must still produce a probeable request; the
    /// gateway answers with a status we can classify, which is the point.
    func testProbeRequestOmitsModelWhenProviderHasNone() throws {
        let provider = StoredProvider(
            app: .claude, name: "Relay", slug: "relay",
            baseURL: "https://relay.example/v1", model: "", apiKey: ""
        )
        let request = try XCTUnwrap(EndpointProbe.makeRequest(for: provider))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try body(of: request)
        XCTAssertNil(body["model"])
    }

    func testMakeRequestReturnsNilForUnusableBaseURL() {
        let provider = StoredProvider(
            app: .claude, name: "Broken", slug: "broken",
            baseURL: "", model: "m", apiKey: ""
        )
        XCTAssertNil(EndpointProbe.makeRequest(for: provider))
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Live smoke test

    /// Opt-in, because it needs a real gateway and the network:
    ///
    ///     ENDPOINT_PROBE_SMOKE=1 swift test --disable-sandbox --filter LiveSmoke
    ///
    /// Probes `ENDPOINT_PROBE_SMOKE_URL` when set, otherwise whatever Claude Code
    /// is currently pointed at. Reads the live config rather than taking a key on
    /// the command line, so no secret ends up in shell history.
    func testProbeAgainstLiveEndpointWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ENDPOINT_PROBE_SMOKE"] == "1" else {
            throw XCTSkip("Set ENDPOINT_PROBE_SMOKE=1 to probe a live endpoint.")
        }

        let provider: StoredProvider
        if let explicit = environment["ENDPOINT_PROBE_SMOKE_URL"], !explicit.isEmpty {
            provider = StoredProvider(
                app: environment["ENDPOINT_PROBE_SMOKE_APP"] == "codex" ? .codex : .claude,
                name: "smoke",
                slug: "smoke",
                baseURL: explicit,
                model: environment["ENDPOINT_PROBE_SMOKE_MODEL"] ?? "",
                apiKey: environment["ENDPOINT_PROBE_SMOKE_KEY"] ?? ""
            )
        } else {
            let loaded = try ClaudeLiveSettingsStore.load(from: LiveConfigPaths.default.claudeSettings)
            try XCTSkipIf(
                loaded.settings.baseURL.isEmpty,
                "No ANTHROPIC_BASE_URL configured; pass ENDPOINT_PROBE_SMOKE_URL instead."
            )
            provider = StoredProvider(
                app: .claude,
                name: "live",
                slug: "live",
                baseURL: loaded.settings.baseURL,
                model: loaded.settings.model,
                apiKey: loaded.secret
            )
        }

        let result = await EndpointProbe.probe(provider)
        print("probe → \(result.summary) · \(result.detail)")
        XCTAssertNotEqual(result.verdict, .unreachable, result.detail)
    }
}
