import XCTest

final class BroadcastWireTests: XCTestCase {
    func testFrameRoundTrip() throws {
        let unit = Data([0, 0, 0, 2, 0x65, 0x88])
        let message = BroadcastWire.frame(lane: 7, keyframe: true, micros: 1_234_567_890_123, accessUnit: unit)
        var reader = BroadcastWire.Reader()
        let out = reader.feed(message)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].0, .frame)
        let (lane, key, micros, au) = try XCTUnwrap(BroadcastWire.parseFrame(out[0].1))
        XCTAssertEqual(lane, 7)
        XCTAssertTrue(key)
        XCTAssertEqual(micros, 1_234_567_890_123)
        XCTAssertEqual(au, unit)
    }

    func testReaderJoinsSplitMessages() throws {
        let lanes = [BroadcastWire.Lane(id: 1, longSide: 1920, fps: 60, codec: "hevc", bitrate: 2_000_000, hold: false, key: true)]
        let a = try XCTUnwrap(BroadcastWire.message(.lanes, json: lanes))
        let b = BroadcastWire.message(.stop)
        let both = a + b
        var reader = BroadcastWire.Reader()
        // Byte by byte, as a socket may hand it over.
        var got: [(BroadcastWire.Kind, Data)] = []
        for i in both.indices { got += reader.feed(both.subdata(in: i..<(i + 1))) }
        XCTAssertEqual(got.map(\.0), [.lanes, .stop])
        XCTAssertEqual(try JSONDecoder().decode([BroadcastWire.Lane].self, from: got[0].1), lanes)
    }

    func testReaderDropsGarbage() {
        var reader = BroadcastWire.Reader()
        // A length of zero can't be a message: the buffer is dropped, not
        // waited on for ever.
        XCTAssertTrue(reader.feed(Data([0, 0, 0, 0, 9, 9])).isEmpty)
        XCTAssertEqual(reader.feed(BroadcastWire.message(.stop)).map(\.0), [.stop])
    }
}
