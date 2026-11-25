// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class LearningTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: QuerySynonyms.userGroupsKey)
        UserDefaults.standard.removeObject(forKey: VoiceFixes.learnedKey)
        UserDefaults.standard.removeObject(forKey: VoiceFixes.enabledKey)
    }

    func testResumeMeansCV() {
        let alts = QuerySynonyms.alternatives(for: "резюме")
        XCTAssertTrue(alts.contains("cv"))
        XCTAssertTrue(alts.contains("resume"))
        XCTAssertTrue(QuerySynonyms.alternatives(for: "CV").contains("резюме"))
        XCTAssertTrue(QuerySynonyms.alternatives(for: "договора").contains("contract"))
        XCTAssertTrue(QuerySynonyms.alternatives(for: "попугай").isEmpty)
    }

    func testDocumentNamedCVMatchesRussianQuery() {
        let groups = DocumentRelevance.termGroups("моё резюме")
        XCTAssertEqual(groups.count, 1)
        let cv = DocumentRelevance.words("CV Alexey Ivanov.pdf QA Engineer, game testing")
        let list = DocumentRelevance.words("Список покупок: молоко, хлеб")
        XCTAssertTrue(DocumentRelevance.isTextMatch(groups: groups, words: cv))
        XCTAssertFalse(DocumentRelevance.isTextMatch(groups: groups, words: list))
    }

    func testMailTermGroupsKeepAcronymAndSynonyms() {
        let groups = MailQuery.termGroups(from: ["резюме"])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].contains("cv"))
        XCTAssertEqual(MailQuery.termGroups(from: ["CV"]).first?.first, "cv")
    }

    func testUserSynonyms() {
        QuerySynonyms.addUserGroup("тачка, машина, car")
        XCTAssertTrue(QuerySynonyms.alternatives(for: "тачку").contains("car"))
    }

    func testVoiceFixes() {
        XCTAssertEqual(VoiceFixes.apply("моё Сири"), "моё CV")
        XCTAssertEqual(VoiceFixes.apply("найди си ви"), "найди CV")
        XCTAssertEqual(VoiceFixes.apply("сирийский"), "сирийский")
        VoiceFixes.learn(heard: "договор с алисой", sent: "договор с Alice")
        XCTAssertEqual(VoiceFixes.learned["алисой"], "Alice")
        // A different query typed over the dictation is not learned.
        VoiceFixes.learn(heard: "собака", sent: "кошка")
        XCTAssertNil(VoiceFixes.learned["собака"])
    }

    func testMediaWordsLeaveTheQuery() {
        let stripped = SearchEngine.stripMediaWords("видео природы")
        XCTAssertEqual(stripped.text, "природы")
        XCTAssertTrue(stripped.video)
        XCTAssertFalse(SearchEngine.stripMediaWords("фото собаки").video)
        XCTAssertFalse(SearchEngine.broadScenes(for: "природы").isEmpty)
        XCTAssertTrue(SearchEngine.broadScenes(for: "попугай").isEmpty)
    }

    func testQueryKeyIgnoresEndingsAndMediaWords() {
        XCTAssertEqual(SearchLearning.queryKey("видео природы"), SearchLearning.queryKey("Природа"))
        XCTAssertNotEqual(SearchLearning.queryKey("собака"), SearchLearning.queryKey("кошка"))
    }
}
