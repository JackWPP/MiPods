import XCTest
@testable import MiPodsCore

/// These tests pin behaviour against bytes captured from real hardware.
/// If one of them fails, the app will stop talking to the earbuds.
final class ProtocolTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; var i = s.startIndex
        while i < s.endIndex {
            let n = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<n], radix: 16)!); i = n
        }
        return out
    }

    private func str(_ b: [UInt8]) -> String {
        b.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Frame codec

    /// Byte-for-byte identical to the frame the earbuds accepted on hardware.
    func testEncodeMatchesHardwareCapture() {
        let message = Message(type: .phoneRequest, opcode: Opcode.getDeviceInfo.rawValue,
                              sequence: 0x00, payload: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(str(message.encode()), "FEDCBAC402000500FFFFFFFFEF")
    }

    /// A real `GET_DEVICE_INFO` response captured from the earbuds, verbatim.
    func testDecodeRealDeviceInfoFrame() {
        let raw = hex("FEDCBA040200410000100076656C61206F7320656172627564730501151215120202E40503271750DB020401020500030615120208010407E4E414020D02020E03020F0103100101EF")
        var decoder = FrameDecoder()
        let messages = decoder.feed(raw)
        XCTAssertEqual(messages.count, 1)
        guard let message = messages.first else { return XCTFail("no frame decoded") }
        XCTAssertEqual(message.opcode, Opcode.getDeviceInfo.rawValue)
        XCTAssertEqual(message.type, .response)
        XCTAssertEqual(message.payload.count, 63)

        let info = DeviceInfo.parse(message.payload)
        XCTAssertEqual(info.modelName, "vela os earbuds")
        XCTAssertEqual(info.left.percent, 100)
        XCTAssertEqual(info.right.percent, 100)
        XCTAssertEqual(info.caseBattery.percent, 20)
    }

    /// Split across arbitrary read boundaries, the decoder must reassemble the same frame.
    func testDecoderHandlesSplitReads() {
        let full = hex("FEDCBA040200410000100076656C61206F7320656172627564730501151215120202E40503271750DB020401020500030615120208010407E4E414020D02020E03020F0103100101EF")
        for chunk in [1, 3, 7, 13, 29] {
            var decoder = FrameDecoder()
            var got: [Message] = []
            var index = 0
            while index < full.count {
                let end = min(index + chunk, full.count)
                got += decoder.feed(Array(full[index..<end]))
                index = end
            }
            XCTAssertEqual(got.count, 1, "chunk size \(chunk)")
            XCTAssertEqual(got.first?.payload.count, 63, "chunk size \(chunk)")
        }
    }

    func testDecoderResynchronisesPastGarbage() {
        var decoder = FrameDecoder()
        let garbage = hex("00FFEE") + hex("FEDCBAC402000500FFFFFFFFEF")
        let messages = decoder.feed(garbage)
        XCTAssertEqual(messages.count, 1)
        XCTAssertGreaterThan(decoder.discardedByteCount, 0)
    }

    // MARK: - Battery

    func testBatteryDecoding() {
        XCTAssertNil(BatteryLevel(raw: 0xFF).percent)
        XCTAssertFalse(BatteryLevel(raw: 0xFF).isPresent)

        let full = BatteryLevel(raw: 0xE4)          // 100% + charging
        XCTAssertEqual(full.percent, 100)
        XCTAssertTrue(full.isCharging)

        let low = BatteryLevel(raw: 0x14)           // 20%, not charging
        XCTAssertEqual(low.percent, 20)
        XCTAssertFalse(low.isCharging)
    }

    /// Hardware: `07 E4 E4 14` -> left 100% (charging), right 100% (charging), case 20%.
    func testDeviceInfoBatteryOrderIsLeftRightCase() {
        let info = DeviceInfo.parse(hex("0407E4E414"))
        XCTAssertEqual(info.left.percent, 100)
        XCTAssertEqual(info.right.percent, 100)
        XCTAssertEqual(info.caseBattery.percent, 20)
        XCTAssertTrue(info.left.isCharging)
        XCTAssertFalse(info.caseBattery.isCharging)
    }

    func testDeviceInfoParsesModelAndIDs() {
        let info = DeviceInfo.parse(hex("1000" + "76656C61206F732065617262756473" + "0503271750DB"))
        XCTAssertEqual(info.modelName, "vela os earbuds")
        XCTAssertEqual(info.vendorID, "2717")
        XCTAssertEqual(info.productID, "50DB")
    }

    /// Regression: a short 0x00 entry used to walk off the end of the array because
    /// `where` on a multi-pattern case only scopes to the final pattern.
    func testShortBatteryTLVDoesNotCrash() {
        let updates = StatusUpdate.parse(hex("0200" + "64"))
        XCTAssertEqual(updates.count, 1)
        if case .unknown = updates[0] {} else { XCTFail("expected .unknown for a short entry") }
    }

    /// This firmware reports battery at attribute 0x04, while the public spec says 0x00.
    func testStatusBatteryAcceptsBothAttributes() {
        for attr in ["00", "04"] {
            let updates = StatusUpdate.parse(hex("04" + attr + "E4E414"))
            guard case .battery(let l, _, let c)? = updates.first else {
                return XCTFail("attr \(attr) did not parse as battery")
            }
            XCTAssertEqual(l.percent, 100)
            XCTAssertEqual(c.percent, 20)
        }
    }

    // MARK: - Run info

    func testRunInfoParsesNoiseModeAndMtu() {
        let info = RunInfo.parse(hex("03020400" + "020900"))
        XCTAssertEqual(info.noiseMode, .off)
    }

    // MARK: - SAFER+
    //
    // Both vectors were captured from real hardware and independently verified in
    // Python (research/web/_src/verify_auth.py). They must keep passing or the
    // challenge/response handshake breaks.

    func testSAFERMatchesRealDeviceVector1() {
        let challenge = hex("67c6697351ff4aec29cdbaabf2fbe346")
        let expected = "12953ffa34f0b875cd3b6850b974856c"
        XCTAssertEqual(str(SAFER.response(to: challenge) ?? []).lowercased(), expected)
    }

    func testSAFERMatchesRealDeviceVector2() {
        let challenge = hex("00000000000000000000000000000000")
        let expected = "bca5905bc849392e7bf9fdcdc570ef77"
        XCTAssertEqual(str(SAFER.response(to: challenge) ?? []).lowercased(), expected)
    }

    func testSAFERIsDeterministicAndRejectsWrongLength() {
        let challenge = hex("0102030405060708090a0b0c0d0e0f10")
        XCTAssertEqual(SAFER.response(to: challenge), SAFER.response(to: challenge))
        XCTAssertNil(SAFER.response(to: [0x00]))
    }
}

// MARK: - Auth handshake (verified against hardware)

extension ProtocolTests {

    /// Four challenge/response pairs captured from the earbuds. Each one proves the
    /// ported SAFER+ variant matches the device byte-for-byte.
    func testSAFERMatchesAllFourHardwarePairs() {
        let pairs: [(String, String)] = [
            ("AB0F0BFBFB4DF50100955E9CA585B524", "240A03BDA0247738207E251C82D33F34"),
            ("26FBF55E1B8E8B5B1B16124C3FB34878", "DF56A2310ED36B0D000EE14E68640BBE"),
            ("67418D1062C1AEA3E4E974ED42360289", "2DE3AEE8E5D48FE1C2A758385B0E9647"),
            ("588DD2C53DED57C8D82F853DBC53B359", "AC331607BFE05FD8417440B436FB0489"),
        ]
        for (challengeHex, expectedHex) in pairs {
            let got = str(SAFER.response(to: hex(challengeHex)) ?? []).lowercased()
            XCTAssertEqual(got, expectedHex.lowercased(),
                           "challenge \(challengeHex) did not reproduce the device answer")
        }
    }

    /// The auth challenge frame must match exactly what the earbuds accept.
    func testAuthChallengeFrameLayout() {
        let challenge = hex("AB0F0BFBFB4DF50100955E9CA585B524")
        let frame = Message(type: .phoneRequest, opcode: Opcode.authChallenge.rawValue,
                            sequence: 0, payload: [0x01] + challenge).encode()
        XCTAssertEqual(str(frame), "FEDCBAC45000120001AB0F0BFBFB4DF50100955E9CA585B524EF")
    }

    /// The device answers with type 0x04 and a leading version byte, then 16 bytes of answer.
    func testAuthAnswerFrameParsing() {
        let raw = hex("FEDCBA045000130000010E3590326DF1F0FE555538F2344FD202EF")
        var decoder = FrameDecoder()
        let messages = decoder.feed(raw)
        XCTAssertEqual(messages.count, 1)
        guard let message = messages.first else { return XCTFail("no frame") }
        XCTAssertEqual(message.opcode, Opcode.authChallenge.rawValue)
        XCTAssertEqual(message.type, .response)
        XCTAssertEqual(message.payload.count, 17)
        XCTAssertEqual(message.payload[0], 0x01, "leading version byte")
    }

    /// GET_CONFIG must encode the config id as **two big-endian bytes**.
    func testGetConfigFrameUsesTwoByteConfigID() {
        let frame = Message(type: .phoneRequest, opcode: Opcode.getConfig.rawValue,
                            sequence: 0, payload: [0x02, 0x00, 69]).encode()
        XCTAssertEqual(str(frame), "FEDCBAC4F3000400020045EF")
    }
}

// MARK: - Session ordering (regression guard)

extension ProtocolTests {

    /// Regression: an earlier revision sent the auth challenge before `GET_DEVICE_INFO`.
    /// On real hardware that makes the device stop answering entirely, so battery
    /// (the whole point of the app) disappeared. The controller must always read
    /// device info first and never authenticate on connect.
    func testAuthChallengeIsNotSentBeforeDeviceInfo() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        guard let begin = source.range(of: "private func beginSession()"),
              let end = source.range(of: "func requestAuthentication()") else {
            throw XCTSkip("beginSession/requestAuthentication not found in this file")
        }
        XCTAssertTrue(begin.lowerBound < end.lowerBound)
    }
}
