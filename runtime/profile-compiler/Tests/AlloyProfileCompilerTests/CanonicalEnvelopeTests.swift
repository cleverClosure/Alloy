// Author: Timur Isaev

import CryptoKit
import Foundation
import JavaScriptCore
import Testing
@testable import AlloyProfileCompiler

func extraFixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(.gameProfile, "..").appendingPathComponent(name))
}

struct TestKey: Decodable {
    let keyId: String
    let privateKey: Data
    let publicKey: Data
}

func testKey() throws -> TestKey {
    try JSONDecoder().decode(TestKey.self, from: extraFixture("TEST-ONLY-key.json"))
}

func signedFixture(
    _ payload: Data, type: PayloadType = .gameProfile, expiry: String = "2030-01-01T00:00:00Z"
) throws -> Data {
    let key = try testKey()
    let claims = try EnvelopeClaims(payload: payload, type: type, expiresAt: expiry)
    let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: key.privateKey)
    let signature = try signer.signature(for: CanonicalJSON.encode(claims))
    return try CanonicalJSON.encode(TestEnvelope(
        claims: claims, keyId: key.keyId, signature: signature.base64EncodedString()
    ))
}

func testVerificationMode() throws -> VerificationMode {
    let key = try testKey()
    return .testOnly(keys: [key.keyId: key.publicKey])
}

let fixtureNow = Date(timeIntervalSince1970: 1_791_072_000) // 2026-10-04T00:00:00Z

@Suite("Canonical encoding and local test envelopes")
struct CanonicalEnvelopeTests {
    @Test func goldenBytesTenRuns() throws {
        let input = try extraFixture("Canonical/input.json")
        let expected = try extraFixture("Canonical/expected.txt")
        for _ in 0..<10 {
            let result = try CanonicalJSON.encode(input)
            #expect(result == expected)
            #expect(try CanonicalJSON.encode(result) == expected)
        }
    }

    @Test func rejectsAmbiguousAndMalformedInput() throws {
        for invalid in [
            #"{"a":1,"\u0061":2}"#, #"{"e\u0301":1,"é":2}"#, #""\ud800""#,
            "[1,]", "{\"a\":1,}", "01", "1e999", "true false", "[", "\"x\\", "+1", ".1",
            String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)
        ] {
            #expect(throws: (any Error).self) { try CanonicalJSON.encode(Data(invalid.utf8)) }
        }
        #expect(throws: (any Error).self) { try CanonicalJSON.encode(Data([34, 255, 34])) }
    }

    @Test func rfcNumberVectorsAndIndependentECMAScriptOracle() throws {
        let context = try #require(JSContext())
        let stringify = try #require(context.evaluateScript("JSON.stringify"))
        let vectors = try JSONDecoder().decode([String: String].self, from: extraFixture("Canonical/numbers.json"))
        for (bits, expected) in vectors {
            let value = Double(bitPattern: try #require(UInt64(bits, radix: 16)))
            #expect(try CanonicalJSON.number(value) == expected)
        }
        var bits: UInt64 = 0x101_CAFE
        for _ in 0..<10_000 {
            bits = bits &* 6_364_136_223_846_793_005 &+ 1
            let value = Double(bitPattern: bits)
            guard value.isFinite else { continue }
            let expected = try #require(stringify.call(withArguments: [value])?.toString())
            #expect(try CanonicalJSON.number(value) == expected, "binary64 bits: \(bits)")
        }
        #expect(throws: (any Error).self) { try CanonicalJSON.number(.nan) }
        #expect(throws: (any Error).self) { try CanonicalJSON.number(.infinity) }
    }

    @Test func signatureTypeExpiryAndUnsignedControls() throws {
        let payload = try fixtureData(.gameProfile, "valid/minimal.json")
        let signed = try signedFixture(payload)
        let mode = try testVerificationMode()
        let verified = try TestEnvelope.verify(signed, type: .gameProfile, mode: mode, now: fixtureNow)
        #expect(verified.verification == "test-only")
        #expect(try GameProfileValidator.validate(verified.bytes).revision == 1)
        var object = try #require(JSONSerialization.jsonObject(with: signed) as? [String: Any])
        object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CompilerFailure.rejected("invalid test signature")) {
            try TestEnvelope.verify(tampered, type: .gameProfile, mode: mode, now: fixtureNow)
        }
        let expired = try signedFixture(payload, expiry: "2020-01-01T00:00:00Z")
        #expect(throws: CompilerFailure.rejected("expired or invalid envelope expiry")) {
            try TestEnvelope.verify(expired, type: .gameProfile, mode: mode, now: fixtureNow)
        }
        #expect(throws: (any Error).self) {
            try TestEnvelope.verify(signed, type: .runtimeManifest, mode: mode, now: fixtureNow)
        }
        let claims = try EnvelopeClaims(payload: payload, type: .gameProfile, expiresAt: "2030-01-01T00:00:00Z")
        let unsigned = try CanonicalJSON.encode(TestEnvelope(claims: claims))
        #expect(throws: (any Error).self) {
            try TestEnvelope.verify(unsigned, type: .gameProfile, mode: mode, now: fixtureNow)
        }
        #expect(try TestEnvelope.verify(unsigned, type: .gameProfile, mode: .development, now: fixtureNow)
            .verification == "unsigned-development")
        #expect(throws: (any Error).self) {
            try TestEnvelope.verify(signed, type: .gameProfile, mode: .development, now: fixtureNow)
        }
    }
}
