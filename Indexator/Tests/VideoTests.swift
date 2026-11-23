// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class VideoTests: XCTestCase {
    func testShortVideoIsSampledEveryTwoSeconds() {
        XCTAssertEqual(VideoSampler.times(duration: 7), [0.5, 2.5, 4.5, 6.5])
        XCTAssertEqual(VideoSampler.times(duration: 0.2), [0])
    }

    func testLongVideoIsCappedAndSpread() {
        let times = VideoSampler.times(duration: 3600)
        XCTAssertEqual(times.count, VideoSampler.maxFrames)
        XCTAssertGreaterThan(times.last ?? 0, 3000)
    }

    func testSameSceneFramesAreDropped() {
        let a = VectorMath.normalized([1, 0, 0])
        let a2 = VectorMath.normalized([1, 0.05, 0])
        let b = VectorMath.normalized([0, 1, 0])
        let frames = [
            VideoFrame(time: 0, vector: a), VideoFrame(time: 2, vector: a2),
            VideoFrame(time: 4, vector: b), VideoFrame(time: 6, vector: a),
        ]
        XCTAssertEqual(VideoSampler.keepSceneChanges(frames).map(\.time), [0, 4, 6])
    }

    func testSpeechIsGroupedIntoTimedChunks() {
        let words: [(time: Double, text: String)] = [
            (0.5, "привет"), (1.0, "это"), (9.0, "собака"), (10.0, "бежит"), (30, "конец"),
        ]
        XCTAssertEqual(VideoSpeech.chunks(from: words), [
            SpeechChunk(time: 0.5, text: "привет это"),
            SpeechChunk(time: 9.0, text: "собака бежит"),
            SpeechChunk(time: 30, text: "конец"),
        ])
    }

    func testTimeFormat() {
        XCTAssertEqual(VideoFormat.time(7.9), "0:07")
        XCTAssertEqual(VideoFormat.time(75), "1:15")
        XCTAssertEqual(VideoFormat.time(3725), "1:02:05")
    }
}
