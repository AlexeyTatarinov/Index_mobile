// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal read-only Gmail REST client: list message ids, fetch one message.
// Used only during an explicit sync; search never calls it.

import Foundation

enum GmailClientError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(403, let body) where body.contains("accessNotConfigured") || body.contains("SERVICE_DISABLED"):
            return "Gmail API не включён в проекте Google Cloud. Включи «Gmail API» в APIs & Services → Library."
        case .http(let code, let body):
            return "Gmail ответил \(code): \(body.prefix(300))"
        }
    }
}

struct GmailClient {
    let auth: GmailAuth
    private let base = "https://gmail.googleapis.com/gmail/v1/users/me/"

    struct Profile: Decodable {
        let emailAddress: String
        let messagesTotal: Int?
    }

    private struct ListResponse: Decodable {
        struct Ref: Decodable { let id: String }
        let messages: [Ref]?
        let nextPageToken: String?
        let resultSizeEstimate: Int?
    }

    func profile() async throws -> Profile {
        try await get("profile", query: [])
    }

    /// All message ids matching a Gmail search query, newest first.
    func messageIds(query: String, limit: Int, onPage: (Int) async -> Void) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var items = [URLQueryItem(name: "maxResults", value: "500"), URLQueryItem(name: "q", value: query)]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: ListResponse = try await get("messages", query: items)
            ids += page.messages?.map(\.id) ?? []
            pageToken = page.nextPageToken
            await onPage(ids.count)
            try Task.checkCancellation()
        } while pageToken != nil && (limit == 0 || ids.count < limit)
        return limit == 0 ? ids : Array(ids.prefix(limit))
    }

    func message(id: String) async throws -> GmailAPIMessage {
        try await get("messages/\(id)", query: [URLQueryItem(name: "format", value: "full")])
    }

    /// GET with a fresh token; refreshes once on 401 and backs off on 429/5xx.
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        var forceRefresh = false
        var delay: UInt64 = 1_000_000_000
        for attempt in 0..<5 {
            let token = try await auth.accessToken(force: forceRefresh)
            forceRefresh = false
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return try JSONDecoder().decode(T.self, from: data)
            case 401 where attempt == 0:
                forceRefresh = true
                continue
            case 429, 500, 502, 503, 504:
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            default:
                throw GmailClientError.http(status, String(decoding: data, as: UTF8.self))
            }
        }
        throw GmailClientError.http(429, "слишком много запросов, попробуй позже")
    }
}
