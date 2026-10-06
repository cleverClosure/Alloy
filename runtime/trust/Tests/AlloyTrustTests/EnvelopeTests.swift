// Author: Timur Isaev

import CryptoKit
import Foundation
import Testing
@testable import AlloyTrust

@Suite struct EnvelopeTests {
    @Test func independentKnownAnswer() throws {
        struct Vector: Decodable {
            let source: String
            let canonical: String
            let pae: String
            let publicKey: String
            let envelope: SignedEnvelope
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vectors/envelope.json")
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: path))
        let payload = Data(vector.canonical.utf8)
        #expect(try TrustCanonicalJSON.encode(Data(vector.source.utf8)) == payload)
        #expect(SignedEnvelope.preAuthenticationEncoding(type: vector.envelope.payloadType, payload: payload)
            .base64EncodedString() == vector.pae)
        let key = try #require(Data(base64Encoded: vector.publicKey))
        #expect(try vector.envelope.verify(type: vector.envelope.payloadType,
                                          keys: [SignedEnvelope.keyID(key): key], threshold: 1) == payload)
    }

    @Test func thresholdsAndTypeBinding() throws {
        let keys = (0..<3).map { _ in Curve25519.Signing.PrivateKey() }
        let authorized = Dictionary(uniqueKeysWithValues: keys.map {
            (SignedEnvelope.keyID($0.publicKey.rawRepresentation), $0.publicKey.rawRepresentation)
        })
        let bytes = Data("{\"answer\":42}".utf8)
        let valid = try SignedEnvelope.sign(bytes, type: "test", keys: Array(keys.prefix(2)))
        #expect(try valid.verify(type: "test", keys: authorized, threshold: 2) == bytes)
        #expect(throws: TrustError.belowThreshold) {
            try valid.verify(type: "test", keys: authorized, threshold: 3)
        }
        let duplicate = SignedEnvelope(payloadType: "test", payload: valid.payload,
                                       signatures: [valid.signatures[0], valid.signatures[0]])
        #expect(throws: TrustError.belowThreshold) {
            try duplicate.verify(type: "test", keys: authorized, threshold: 2)
        }
        #expect(throws: TrustError.wrongRole) {
            try valid.verify(type: "wrong", keys: authorized, threshold: 2)
        }
        let substituted = SignedEnvelope(payloadType: "wrong", payload: valid.payload, signatures: valid.signatures)
        #expect(throws: TrustError.belowThreshold) {
            try substituted.verify(type: "wrong", keys: authorized, threshold: 2)
        }
        let tampered = SignedEnvelope(payloadType: "test", payload: Data("null".utf8).base64EncodedString(),
                                      signatures: valid.signatures)
        #expect(throws: TrustError.belowThreshold) {
            try tampered.verify(type: "test", keys: authorized, threshold: 2)
        }
        #expect(throws: TrustError.invalidRoot) {
            try valid.verify(type: "test", keys: ["alias": keys[0].publicKey.rawRepresentation], threshold: 1)
        }
    }

    @Test func malformedControls() throws {
        for text in ["{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "[NaN]", "1e999", "true false",
                     "\"\\ud800\"", "[01]", "{\"x\":}", String(repeating: "[", count: 66) + "0"] {
            #expect(throws: (any Error).self) { try TrustCanonicalJSON.encode(Data(text.utf8)) }
        }
        let envelope = try SignedEnvelope.sign(Data("{}".utf8), type: "test", keys: [.init()])
        let encoded = try TrustCanonicalJSON.encode(envelope)
        #expect(try SignedEnvelope.decode(encoded).payload == envelope.payload)
        let withUnknown = Data((String(bytes: encoded.dropLast(), encoding: .utf8)! + ",\"extra\":1}").utf8)
        #expect(throws: (any Error).self) { try SignedEnvelope.decode(withUnknown) }
        let whitespace = SignedEnvelope(payloadType: "test", payload: Data("{ }".utf8).base64EncodedString(),
                                        signatures: envelope.signatures)
        #expect(throws: (any Error).self) { try whitespace.decodedPayload() }
    }
}
