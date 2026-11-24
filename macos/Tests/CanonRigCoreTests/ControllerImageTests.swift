import CryptoKit
import Foundation
import Testing
@testable import CanonRigCore

func testFirmwareImage() -> ControllerImage? {
    var data = Data(repeating: 0, count: 1800)
    data[0] = 0xe9
    data[12] = 2
    data[23] = 1
    data.replaceSubrange(32..<36, with: [0x32, 0x54, 0xcd, 0xab])
    data.replaceSubrange(48..<53, with: "0.2.0".utf8)
    data.replaceSubrange(80..<89, with: "light_rig".utf8)
    data.append(contentsOf: SHA256.hash(data: data))
    return ControllerImage(data)
}

@Test func firmwareRejectsCorruptImagesWrongBoardsAndDowngrades() throws {
    let image = try #require(testFirmwareImage())
    #expect(image.isNewer(than: "0.1.12"))
    for version in ["0.2.0", "0.10.0", "unknown", "0.01.0"] { #expect(!image.isNewer(than: version)) }
    var corrupt = image.bytes
    corrupt[400] ^= 1
    #expect(ControllerImage(corrupt) == nil)
    var board = RigState()
    board.firmware = "0.1.0"
    #expect(!image.supports(board))
    board.isLegacyLightController = true
    #expect(image.supports(board))
    board.firmwareTarget = "other-board"
    #expect(!image.supports(board))
}
