// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class MailParserTests: XCTestCase {
    private func b64url(_ s: String, encoding: String.Encoding = .utf8) -> String {
        PKCE.base64URL(s.data(using: encoding)!)
    }

    func testPrefersPlainTextOverHTML() {
        let message = GmailAPIMessage(
            id: "m1", threadId: "t1", labelIds: ["INBOX"], snippet: "Привет &amp; пока", internalDate: "1700000000000",
            payload: GmailPart(
                partId: "", mimeType: "multipart/alternative", filename: "",
                headers: [GmailHeader(name: "Subject", value: "Тема"), GmailHeader(name: "From", value: "Петя <p@x.ru>")],
                body: GmailBody(size: 0, data: nil, attachmentId: nil),
                parts: [
                    GmailPart(partId: "0", mimeType: "text/plain", filename: "",
                              headers: [GmailHeader(name: "Content-Type", value: "text/plain; charset=\"UTF-8\"")],
                              body: GmailBody(size: 10, data: b64url("Билет   на поезд\r\n\r\n\r\nВагон 12"), attachmentId: nil), parts: nil),
                    GmailPart(partId: "1", mimeType: "text/html", filename: "", headers: nil,
                              body: GmailBody(size: 10, data: b64url("<p>HTML</p>"), attachmentId: nil), parts: nil),
                    GmailPart(partId: "2", mimeType: "application/pdf", filename: "ticket.pdf", headers: nil,
                              body: GmailBody(size: 1000, data: nil, attachmentId: "a1"), parts: nil),
                ]
            )
        )
        let m = MailParser.parse(message)
        XCTAssertEqual(m.subject, "Тема")
        XCTAssertEqual(m.senderName, "Петя")
        XCTAssertEqual(m.body, "Билет на поезд\n\nВагон 12")
        XCTAssertEqual(m.snippet, "Привет & пока")
        XCTAssertEqual(m.attachments, ["ticket.pdf"])
        XCTAssertEqual(m.date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testHTMLFallbackAndCharset() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Счёт&nbsp;за&nbsp;свет</p><br>84&#44;20 &euro;</body></html>"
        let message = GmailAPIMessage(
            id: "m2", threadId: nil, labelIds: nil, snippet: nil, internalDate: nil,
            payload: GmailPart(partId: "", mimeType: "text/html", filename: "",
                               headers: [GmailHeader(name: "Content-Type", value: "text/html; charset=windows-1251")],
                               body: GmailBody(size: 1, data: b64url(html, encoding: .windowsCP1251), attachmentId: nil), parts: nil)
        )
        let m = MailParser.parse(message)
        XCTAssertTrue(m.body.contains("Счёт за свет"), m.body)
        XCTAssertTrue(m.body.contains("84,20 €"), m.body)
        XCTAssertFalse(m.body.contains("color"))
        XCTAssertEqual(m.threadId, "m2")
    }

    func testDisplayName() {
        XCTAssertEqual(MailParser.displayName("\"Иван Петров\" <ivan@example.com>"), "Иван Петров")
        XCTAssertEqual(MailParser.displayName("<a@b.c>"), "a@b.c")
        XCTAssertEqual(MailParser.displayName("a@b.c"), "a@b.c")
    }

    func testPassagesAreChunked() {
        let body = String(repeating: "слово ", count: 400)
        let m = MailMessage(id: "x", threadId: "x", subject: "Тема", sender: "A <a@b.c>", recipients: "", date: nil,
                            snippet: "", body: body, labels: [], attachments: [])
        let p = MailParser.passages(for: m)
        XCTAssertEqual(p.count, 4)
        XCTAssertTrue(p[0].hasPrefix("Тема — A\n"))
        XCTAssertTrue(p.allSatisfy { $0.count <= 820 })
    }
}

final class GmailAuthTests: XCTestCase {
    func testClientIdAndRedirect() {
        XCTAssertNil(GoogleOAuthConfig(clientId: "abc"))
        let c = try! XCTUnwrap(GoogleOAuthConfig(clientId: " 123-abc.apps.googleusercontent.com\n"))
        XCTAssertEqual(c.redirectScheme, "com.googleusercontent.apps.123-abc")
        XCTAssertEqual(c.redirectURI, "com.googleusercontent.apps.123-abc:/oauthredirect")
        let url = c.authorizationURL(challenge: "ch", state: "st").absoluteString
        XCTAssertTrue(url.contains("code_challenge_method=S256"))
        XCTAssertTrue(url.contains("gmail.readonly"))
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCallbackParsing() throws {
        let ok = URL(string: "com.googleusercontent.apps.1:/oauthredirect?state=s1&code=4/abc")!
        XCTAssertEqual(try GmailAuth.code(from: ok, expectedState: "s1"), "4/abc")
        XCTAssertThrowsError(try GmailAuth.code(from: ok, expectedState: "other"))
        let denied = URL(string: "com.googleusercontent.apps.1:/oauthredirect?error=access_denied&state=s1")!
        XCTAssertThrowsError(try GmailAuth.code(from: denied, expectedState: "s1"))
    }

    func testGmailQuery() {
        XCTAssertEqual(MailEngine.gmailQuery(period: .year1, skipPromotions: true),
                       "-in:spam -in:trash -in:chats newer_than:12m -category:promotions -category:social")
        XCTAssertEqual(MailEngine.gmailQuery(period: .all, skipPromotions: false), "-in:spam -in:trash -in:chats")
    }
}

final class MailStoreTests: XCTestCase {
    private func makeStore() throws -> MailStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mail-\(UUID().uuidString).sqlite").path
        return try MailStore(path: path)
    }

    func testWordSearchAndDateFilter() async throws {
        let store = try makeStore()
        try await store.insert(MailDemo.messages)
        let count = await store.count
        XCTAssertEqual(count, MailDemo.messages.count)

        let hits = await store.search(words: ["билет", "поезд"], queryVector: nil, model: nil, filter: nil)
        XCTAssertEqual(hits.first?.id, "demo1")
        XCTAssertTrue(hits.first?.textMatch ?? false)

        // Attachment names are searchable too.
        let pdf = await store.search(words: ["facture"], queryVector: nil, model: nil, filter: nil)
        XCTAssertEqual(pdf.first?.id, "demo2")

        let autumn = QueryParser.parse("осенью 2025")
        let dated = await store.search(words: [], queryVector: nil, model: nil, filter: autumn.dateFilter)
        XCTAssertEqual(Set(dated.map(\.id)), ["demo2", "demo4", "demo5"])
    }

    func testVectorsAndPending() async throws {
        let store = try makeStore()
        try await store.insert(Array(MailDemo.messages.prefix(2)))
        var pending = await store.pendingEmbeddingCount(model: "fake")
        XCTAssertEqual(pending, 2)
        try await store.saveVectors(["demo1": [[1, 0, 0]], "demo2": [[0, 1, 0], [0, 0.6, 0.8]]], model: "fake")
        pending = await store.pendingEmbeddingCount(model: "fake")
        XCTAssertEqual(pending, 0)
        let hits = await store.search(words: [], queryVector: [0, 0, 1], model: "fake", filter: nil)
        XCTAssertEqual(hits.first?.id, "demo2")
        XCTAssertEqual(hits.first?.score ?? 0, 0.8, accuracy: 0.001)

        await store.deleteAll()
        let empty = await store.count
        XCTAssertEqual(empty, 0)
    }
}
