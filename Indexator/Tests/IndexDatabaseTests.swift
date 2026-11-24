// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class IndexDatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ id: String, _ value: Float, text: String = "") -> PhotoRecord {
        PhotoRecord(id: id, created: Date(timeIntervalSince1970: 1_700_000_000 + Double(value)),
                    latitude: nil, longitude: nil, vector: [value, value + 0.5], text: text)
    }

    func testRemoveKeepsMirrorAndDiskInStep() throws {
        let db = try IndexDatabase(model: "test", directory: directory)
        db.begin()
        try db.insert(record("a", 1, text: "чек магазин"))
        try db.insert(record("b", 2))
        try db.insert(record("c", 3, text: "паспорт"))
        db.commit()

        db.remove(ids: ["b", "missing"])

        XCTAssertEqual(db.ids, ["a", "c"])
        XCTAssertEqual(db.vectors, [1, 1.5, 3, 3.5])
        XCTAssertEqual(db.created.count, 2)
        XCTAssertFalse(db.contains("b"))
        XCTAssertEqual(db.textMatches(words: ["паспорт"]), [1])

        // Reopening reads the same rows from disk.
        let reopened = try IndexDatabase(model: "test", directory: directory)
        XCTAssertEqual(reopened.ids, ["a", "c"])
        XCTAssertEqual(reopened.vectors, [1, 1.5, 3, 3.5])
    }

    func testRemoveDuringOpenTransaction() throws {
        let db = try IndexDatabase(model: "test", directory: directory)
        db.begin()
        try db.insert(record("a", 1, text: "квитанция"))
        db.remove(ids: ["a"])
        try db.insert(record("d", 4))
        db.commit()
        XCTAssertEqual(db.ids, ["d"])
        XCTAssertTrue(db.textMatches(words: ["квитанция"]).isEmpty)
        XCTAssertEqual(try IndexDatabase(model: "test", directory: directory).ids, ["d"])
    }

    func testSyncSummary() {
        XCTAssertEqual(PhotoSyncResult().summary, "фото: без изменений")
        XCTAssertEqual(PhotoSyncResult(added: 3, removed: 1, remaining: 10).summary, "фото: +3, −1, осталось 10")
        XCTAssertFalse(PhotoSyncResult(added: 3, remaining: 10).isComplete)
        XCTAssertEqual(PhotoSyncResult(skipped: "нет доступа к фото").summary, "фото: нет доступа к фото")
    }
}
