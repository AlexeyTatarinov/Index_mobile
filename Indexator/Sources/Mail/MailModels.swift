// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain data types of the mail module. Emails are downloaded once from Gmail
// and then live only in the local SQLite file; search never touches the network.

import Foundation

/// One email as stored on the phone.
struct MailMessage: Equatable {
    let id: String              // Gmail message id
    let threadId: String
    let subject: String
    let sender: String          // "Name <address>" as in the From header
    let recipients: String
    let date: Date?
    let snippet: String
    let body: String            // plain text, HTML already stripped
    let labels: [String]
    let attachments: [String]   // file names only, contents are not downloaded

    /// Name if present, otherwise the address.
    var senderName: String { MailParser.displayName(sender) }
}

/// A search result, mapped to the shared result card by the UI.
struct MailHit: Identifiable, Hashable {
    let id: String              // Gmail message id, pass to MailDetailView(messageId:)
    let subject: String
    let sender: String          // display name or address
    let snippet: String
    let date: Date?
    let score: Float            // meaning similarity, 0 when only words matched
    let textMatch: Bool         // query words were found in the email
}

/// Text embedder used for emails. The documents module provides the real one
/// (multilingual-e5-small); without it mail search falls back to words only.
protocol MailTextEmbedding: AnyObject {
    var modelName: String { get }
    func embed(query: String) throws -> [Float]
    func embed(passages: [String]) throws -> [[Float]]
}

enum MailEmbedderProvider {
    /// Returns the shared embedder or throws when the model is not bundled.
    nonisolated(unsafe) static var make: (() throws -> MailTextEmbedding)? = nil
}
