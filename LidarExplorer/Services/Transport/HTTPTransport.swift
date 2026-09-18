//
//  HTTPTransport.swift
//  LidarExplorer
//
//  Shared HTTP transport with bounded retry.
//

import Foundation
import os

/// Errors surfaced by ``HTTPTransport``.
public nonisolated enum TransportError: Error, Sendable, Equatable {
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

    public nonisolated static let shared = HTTPTransport()

    private let session: URLSession

    /// Earliest time the next request to a given host may start.
    private var nextAllowedRequest: [String: Date] = [:]

    /// Minimum spacing between requests to the same host.
    ///
    /// Configurable because the right value is service-specific. A one
    /// request per second cap suits a query API like Overpass, but it would
    /// serialise raster tile loading and make panning crawl — tiles are
    /// fetched many at a time and each takes about a second, so throughput
    /// depends on overlapping them.
    private let minimumHostInterval: TimeInterval

    public init(session: URLSession? = nil, minimumHostInterval: TimeInterval = 0) {
        self.minimumHostInterval = minimumHostInterval
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            // Tiles are fetched in parallel; each is latency-bound at about a
            // second, so concurrency is what makes panning feel responsive.
            config.httpMaximumConnectionsPerHost = 8
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

                // 206 is a byte-range request's success status (COG tile
                // fetches ask for one); every other caller only ever gets 200.
                if http.statusCode == 200 || http.statusCode == 206 {
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

            // Truncated exponential backoff with full jitter to avoid synchronized stampedes.
            let maxBackoffSeconds = min(0.5 * pow(2.0, Double(attempt - 1)), 8.0)
            let jitteredSeconds = Double.random(in: 0.1...maxBackoffSeconds)
            let backoffNanoseconds = UInt64(jitteredSeconds * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: backoffNanoseconds)
            } catch {
                return .failure(.cancelled)
            }
            Log.network.debug("Retrying \(host, privacy: .public) attempt \(attempt + 1)")
        }

        return .failure(lastError)
    }

    /// Sleeps as needed so consecutive requests to one host stay spaced out.
    private func paceRequest(to host: String) async {
        guard minimumHostInterval > 0 else { return }
        let now = Date()
        let scheduled = max(now, nextAllowedRequest[host] ?? now)
        nextAllowedRequest[host] = scheduled.addingTimeInterval(minimumHostInterval)
        if scheduled > now {
            let delay = scheduled.timeIntervalSince(now)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
