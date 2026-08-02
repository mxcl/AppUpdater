@testable import AppUpdater
import CryptoKit
import XCTest

final class AttestationPrimitiveTests: XCTestCase {
    func testCanonicalJSON() throws {
        let value = try JSONSerialization.jsonObject(with: Data(#"{"z":1,"a":[true,"x"]}"#.utf8))
        XCTAssertEqual(
            String(data: try JSONCanonicalizer.canonicalize(value), encoding: .utf8),
            #"{"a":[true,"x"],"z":1}"#
        )
    }

    func testDERRejectsTrailingAndTruncatedData() throws {
        XCTAssertThrowsError(try DER.parse(Data([0x30, 0x01])))
        XCTAssertThrowsError(try DER.parse(Data([0x05, 0x00, 0x00])))
        XCTAssertEqual(try DER.parse(Data([0x05, 0x00])).tag, 0x05)
    }

    func testSnappyLiteralAndOverlappingCopy() throws {
        let encoded = Data([0x09, 0x08]) + Data("abc".utf8) + Data([0x16, 0x03, 0x00])
        XCTAssertEqual(try Snappy.decompress(encoded, maximumOutputBytes: 9), Data("abcabcabc".utf8))
        XCTAssertThrowsError(try Snappy.decompress(encoded, maximumOutputBytes: 8))
    }

    func testP256SignatureVerification() throws {
        let key = P256.Signing.PrivateKey()
        let message = Data("signed".utf8)
        let signature = try key.signature(for: message)
        XCTAssertNoThrow(
            try SignatureVerifier.verifyP256(
                spkiDER: key.publicKey.derRepresentation,
                signatureDER: signature.derRepresentation,
                message: message
            )
        )
        XCTAssertThrowsError(
            try SignatureVerifier.verifyP256(
                spkiDER: key.publicKey.derRepresentation,
                signatureDER: signature.derRepresentation,
                message: Data("tampered".utf8)
            )
        )
    }

    func testMerkleSingleLeaf() throws {
        let body = Data("entry".utf8)
        let root = (Data([0]) + body).sha256
        XCTAssertNoThrow(
            try Merkle.verify(body: body, leafIndex: 0, treeSize: 1, hashes: [], expectedRoot: root)
        )
    }

}
