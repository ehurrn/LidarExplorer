//
//  HTTPTransport.swift
//  LidarExplorer
//
//  Shared HTTP transport with bounded retry.
//

import Foundation
import os

/// Errors surfaced by ``HTTPTransport``.
public nonisolated enum TransportError: Error, Sendable {
    case badStatus(code: Int)
    case emptyBody
    case cancelled
    case underlying(String)

    public var description: String {
        switch self {
        case .badStatus(let code): "HTTP \(code)"
        case .emptyBody: "empty response"
        case .cancelled: "cancelled"
        case .underlying(let text): text
        }
    }
}

/// A single shared URLSession with sane geospatial-service defaults.
///
/// An `actor` so the session and its configuration are confined to one
/// isolation domain, and so per-host politeness can be enforced centrally —
/// several of the upstream services here (Overpass in particular) will
/// rate-limit or ban a client that fans out requests without pacing.
public actor HTTPTransport {

    public static let shared = HTTPTransport()

    private let session: URLSession

    /// Earliest time the next request to a given host may start.
    private var nextAllowedRequest: [String: Date] = [:]

    /// Minimum spacing between requests to the same host.
    ///
    /// Overpass asks for at most one query at a time from a client, and the
    /// USGS ImageServer will throttle aggressive callers. Pacing here is
    /// cheaper than handling bans downstream.
    private static let minimumHostInterval: TimeInterval = 1.0

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            config.httpMaximumConnectionsPerHost = 4
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadRevalidatingCacheData
            config.httpAdditionalHeaders = [
                // Overpass and Wikidata both require a descriptive agent and
                // will reject or throttle generic ones.
                "User-Agent": "LidarExplorer/1.0 (github.com/ehurrn/LidarExplorer)"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    /// Performs a request, retrying transient failures with backoff.
    ///
    /// Retries only on 5xx, 429, and transport-level errors. A 4xx other than
    /// 429 is a client mistake and retrying it just wastes the user's battery
    /// and the service's goodwill.
    public func data(
        for request: URLRequest,
        maxAttempts: Int = 3
    ) async -> Result<Data, TransportError> {
        guard let host = request.url?.host() else {
            return .failure(.underlying("malformed URL"))
        }

        var lastError: TransportError = .emptyBody

        for attempt in 1...max(maxAttempts, 1) {
            await paceRequest(to: host)

            do {
                let (data, response) = try await session.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    lastError = .underlying("non-HTTP response")
                    break
                }

                if http.statusCode == 200 {
                    guard !data.isEmpty else { return .failure(.emptyBody) }
                    return .success(data)
                }

                lastError = .badStatus(code: http.statusCode)
                let retryable = http.statusCode >= 500 || http.statusCode == 429
                guard retryable, attempt < maxAttempts else {
                    return .failure(lastError)
                }
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch {
                if (error as? URLError)?.code == .cancelled {
                    return .failure(.cancelled)
                }
                lastError = .underlying(error.localizedDescription)
                guard attempt < maxAttempts else { return .failure(lastError) }
            }

            // Exponential backoff: 0.5s, 1s, 2s...
            let backoff = UInt64(0.5 * pow(2, Double(attempt - 1)) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: backoff)
            Log.network.debug("Retrying \(host, privacy: .public) attempt \(attempt + 1)")
        }

        return .failure(lastError)
    }

    /// Sleeps as needed so consecutive requests to one host stay spaced out.
    private func paceRequest(to host: String) async {
        let now = Date()
        if let earliest = nextAllowedRequest[host], earliest > now {
            let delay = earliest.timeIntervalSince(now)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        nextAllowedRequest[host] = Date().addingTimeInterval(Self.minimumHostInterval)
    }
}
