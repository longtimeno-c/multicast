import CryptoKit
import Foundation

// MARK: - Threat model and design
//
// The hub controls audio in someone's home and can read their music library, so a remote must
// be paired before it can do anything, and every later session is mutually authenticated and
// encrypted.
//
// PAIRING: the hub shows a 6-digit code; the person types it on the remote. This is the
// "passkey entry" association model, and it uses the passkey-entry protocol of Bluetooth
// Secure Simple Pairing (Core Spec v5.x, Vol 3 Part H §2.3.5.6.3), with CryptoKit primitives:
//   1. Both sides send fresh X25519 public keys (PKr from the remote, PKh from the hub).
//   2. For each of the code's 20 bits r_i (10^6 < 2^20), in order:
//        remote → hub   Cr_i = HMAC-SHA256(key: Nr_i, "commit" ‖ remote ‖ i ‖ PKr ‖ PKh ‖ r_i)
//        hub → remote   Ch_i = HMAC-SHA256(key: Nh_i, "commit" ‖ hub ‖ i ‖ PKh ‖ PKr ‖ r_i)
//        remote → hub   Nr_i          hub checks Cr_i against ITS bit, aborts on mismatch
//        hub → remote   Nh_i          remote checks Ch_i against ITS bit, aborts on mismatch
//      with fresh random 32-byte nonces. A commitment hides its bit (random HMAC key) and binds
//      it (opening one commitment to both bits needs an HMAC-SHA256 collision).
//   3. LTK ‖ confirm-key = HKDF-SHA256(X25519(PK…), salt: "multicast-pair-v1", info: SHA-256 of
//      the whole transcript: ids, both public keys, the code, every commitment and nonce).
//   4. Each side sends HMAC(confirm-key, role ‖ transcript) and checks the other's.
// A man in the middle has to commit to each bit before it learns it from either side, so it
// gets through one attempt with probability 2^-20; a passive listener learns nothing about the
// key (X25519). The code bits that an aborted run reveals are useless because the hub draws a
// fresh code for every attempt and the remote refuses to resend a code that already failed.
//
// SESSIONS: the remote sends a nonce and an ephemeral X25519 key; the hub answers with its own
// nonce, ephemeral key and HMAC(LTK, "hub" ‖ transcript); the remote checks it and answers with
// HMAC(LTK, "remote" ‖ transcript). Session keys = HKDF(X25519(ephemerals), salt: LTK, info:
// transcript), one per direction (forward secrecy against a later LTK leak for recorded
// sessions). Frames are sealed with ChaCha20-Poly1305 using an implicit per-direction 64-bit
// counter as nonce, so a replayed, dropped, reordered or modified frame fails to open and ends
// the session.

/// Length-prefixed concatenation, so "ab"‖"c" and "a"‖"bc" never hash the same.
struct Transcript {
    private(set) var bytes = Data()

    init(_ label: String) { append(label) }

    mutating func append(_ data: Data) {
        let n = UInt32(data.count)
        bytes.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        bytes.append(data)
    }

    mutating func append(_ string: String) { append(Data(string.utf8)) }

    mutating func append(_ value: UInt64) {
        append(Data((0..<8).map { UInt8(value >> UInt64(56 - 8 * $0) & 0xFF) }))
    }

    var digest: Data { Data(SHA256.hash(data: bytes)) }
}

enum CryptoRole: String, Sendable {
    case remote, hub

    var other: CryptoRole { self == .remote ? .hub : .remote }
}

func randomBytes(_ count: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
}

private func hmac(_ key: SymmetricKey, _ message: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
}

/// X25519 with a check that the result isn't all zeros (a low-order peer key).
private func agree(_ own: Curve25519.KeyAgreement.PrivateKey, _ peerRaw: Data) throws -> SharedSecret {
    let peer: Curve25519.KeyAgreement.PublicKey
    do {
        peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerRaw)
    } catch {
        throw RemoteLinkError.malformed("public key")
    }
    let secret = try own.sharedSecretFromKeyAgreement(with: peer)
    let allZero = secret.withUnsafeBytes { $0.allSatisfy { $0 == 0 } }
    guard !allZero else { throw RemoteLinkError.authenticationFailed("Invalid key exchange.") }
    return secret
}

// MARK: - Pairing codes

public enum PairingCode {
    public static let digits = 6
    static let bitCount = 20

    /// A uniformly random code, zero-padded ("004217").
    public static func random() -> String {
        var g = SystemRandomNumberGenerator()
        return format(UInt32.random(in: 0..<1_000_000, using: &g))
    }

    static func format(_ value: UInt32) -> String {
        let s = String(value)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    /// The code typed by a person: exactly six digits once spaces and dashes are removed.
    public static func parse(_ text: String) -> UInt32? {
        let digitsOnly = text.filter { !$0.isWhitespace && $0 != "-" }
        guard digitsOnly.count == digits, digitsOnly.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt32(digitsOnly)
    }
}

// MARK: - Passkey pairing

enum PairingError: Error, Equatable {
    /// A peer's commitment didn't open to our bit: wrong code, or someone in the middle.
    case codeMismatch
    case outOfOrder
    case confirmationFailed
}

/// One side of the passkey-entry exchange. Pure state machine: the caller moves messages.
struct PasskeyPairing {
    static let rounds = PairingCode.bitCount
    static let nonceLength = 32

    let role: CryptoRole
    let remoteID: String
    let hubID: String
    private let ownKey: Curve25519.KeyAgreement.PrivateKey
    let ownPublicKey: Data
    let peerPublicKey: Data
    private let code: UInt32
    private var ownNonces: [Data] = []
    private var peerCommitments: [Data] = []
    private var transcript: Transcript

    init(role: CryptoRole, code: UInt32, remoteID: String, hubID: String,
         ownKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data) throws {
        guard peerPublicKey.count == 32 else { throw RemoteLinkError.malformed("public key") }
        self.role = role
        self.code = code
        self.remoteID = remoteID
        self.hubID = hubID
        self.ownKey = ownKey
        self.ownPublicKey = ownKey.publicKey.rawRepresentation
        self.peerPublicKey = peerPublicKey
        let remoteKey = role == .remote ? ownPublicKey : peerPublicKey
        let hubKey = role == .hub ? ownPublicKey : peerPublicKey
        transcript = Transcript("multicast-pair-transcript-v1")
        transcript.append(remoteID)
        transcript.append(hubID)
        transcript.append(remoteKey)
        transcript.append(hubKey)
        transcript.append(UInt64(code))
    }

    private func bit(_ i: Int) -> UInt8 { UInt8(code >> UInt32(i) & 1) }

    private static func commitment(nonce: Data, committer: CryptoRole, index: Int,
                                   committerKey: Data, otherKey: Data, bit: UInt8) -> Data {
        var m = Transcript("multicast-pair-commit-v1")
        m.append(committer.rawValue)
        m.append(UInt64(index))
        m.append(committerKey)
        m.append(otherKey)
        m.append(Data([bit]))
        return hmac(SymmetricKey(data: nonce), m.bytes)
    }

    /// Our commitment for round `index` (draws this round's nonce).
    mutating func makeCommitment(_ index: Int) throws -> Data {
        guard index == ownNonces.count, index < Self.rounds else { throw PairingError.outOfOrder }
        let nonce = randomBytes(Self.nonceLength)
        ownNonces.append(nonce)
        let c = Self.commitment(nonce: nonce, committer: role, index: index, committerKey: ownPublicKey,
                                otherKey: peerPublicKey, bit: bit(index))
        transcript.append(c)
        return c
    }

    mutating func receiveCommitment(_ index: Int, _ commitment: Data) throws {
        guard index == peerCommitments.count, index < Self.rounds, commitment.count == 32 else {
            throw PairingError.outOfOrder
        }
        peerCommitments.append(commitment)
        transcript.append(commitment)
    }

    /// Our nonce for round `index`, to reveal once the peer's commitment for it has arrived.
    mutating func reveal(_ index: Int) throws -> Data {
        guard index < ownNonces.count, index < peerCommitments.count else { throw PairingError.outOfOrder }
        transcript.append(ownNonces[index])
        return ownNonces[index]
    }

    /// Checks the peer's revealed nonce against its commitment and OUR bit for this round.
    mutating func verifyReveal(_ index: Int, _ nonce: Data) throws {
        guard index < peerCommitments.count, nonce.count == Self.nonceLength else { throw PairingError.outOfOrder }
        let expected = Self.commitment(nonce: nonce, committer: role.other, index: index, committerKey: peerPublicKey,
                                       otherKey: ownPublicKey, bit: bit(index))
        guard constantTimeEqual(expected, peerCommitments[index]) else { throw PairingError.codeMismatch }
        transcript.append(nonce)
    }

    var isComplete: Bool { ownNonces.count == Self.rounds && peerCommitments.count == Self.rounds }

    /// The long-term key and the key-confirmation key. Only after all rounds.
    func deriveKeys() throws -> (longTermKey: SymmetricKey, confirmKey: SymmetricKey) {
        guard isComplete else { throw PairingError.outOfOrder }
        let secret = try agree(ownKey, peerPublicKey)
        let okm = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("multicast-pair-v1".utf8),
                                                 sharedInfo: transcript.digest, outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }

    func confirmation(for who: CryptoRole, confirmKey: SymmetricKey) -> Data {
        var m = Transcript("multicast-pair-confirm-v1")
        m.append(who.rawValue)
        m.append(transcript.digest)
        return hmac(confirmKey, m.bytes)
    }

    func verifyConfirmation(_ mac: Data, confirmKey: SymmetricKey) throws {
        guard constantTimeEqual(confirmation(for: role.other, confirmKey: confirmKey), mac) else {
            throw PairingError.confirmationFailed
        }
    }
}

func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}

// MARK: - Session handshake

struct SessionKeys {
    var remoteToHub: SymmetricKey
    var hubToRemote: SymmetricKey
}

enum SessionHandshake {
    static let nonceLength = 32

    static func transcript(version: Int, remoteID: String, hubID: String, remoteNonce: Data, remoteEphemeral: Data,
                           hubNonce: Data, hubEphemeral: Data) -> Data {
        var t = Transcript("multicast-session-v1")
        t.append(UInt64(version))
        t.append(remoteID)
        t.append(hubID)
        t.append(remoteNonce)
        t.append(remoteEphemeral)
        t.append(hubNonce)
        t.append(hubEphemeral)
        return t.digest
    }

    static func proof(longTermKey: SymmetricKey, role: CryptoRole, transcript: Data) -> Data {
        var m = Transcript("multicast-session-proof-v1")
        m.append(role.rawValue)
        m.append(transcript)
        return hmac(longTermKey, m.bytes)
    }

    static func verify(_ mac: Data, longTermKey: SymmetricKey, role: CryptoRole, transcript: Data) -> Bool {
        constantTimeEqual(proof(longTermKey: longTermKey, role: role, transcript: transcript), mac)
    }

    static func keys(ownEphemeral: Curve25519.KeyAgreement.PrivateKey, peerEphemeral: Data,
                     longTermKey: SymmetricKey, transcript: Data) throws -> SessionKeys {
        let secret = try agree(ownEphemeral, peerEphemeral)
        let salt = longTermKey.withUnsafeBytes { Data($0) }
        let okm = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: transcript,
                                                 outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return SessionKeys(remoteToHub: SymmetricKey(data: bytes.prefix(32)),
                           hubToRemote: SymmetricKey(data: bytes.suffix(32)))
    }
}

// MARK: - Sealed frames

/// Seals frames in one direction. The nonce is the frame's sequence number, never sent.
struct FrameSealer {
    private let key: SymmetricKey
    private let label: Data
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey, direction: String) {
        self.key = key
        self.label = Data(direction.utf8)
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        guard counter < UInt64.max else { throw RemoteLinkError.closed("Session exhausted its nonces.") }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: frameNonce(counter), authenticating: label)
        counter += 1
        return box.ciphertext + box.tag
    }
}

/// Opens frames from the other direction, in order. Any failure is final for the session.
struct FrameOpener {
    private let key: SymmetricKey
    private let label: Data
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey, direction: String) {
        self.key = key
        self.label = Data(direction.utf8)
    }

    mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw RemoteLinkError.authenticationFailed("A sealed frame was too short.") }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: frameNonce(counter), ciphertext: sealed.dropLast(16),
                                               tag: sealed.suffix(16))
            let plain = try ChaChaPoly.open(box, using: key, authenticating: label)
            counter += 1
            return plain
        } catch {
            throw RemoteLinkError.authenticationFailed("A frame failed authentication.")
        }
    }
}

private func frameNonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
    var bytes = [UInt8](repeating: 0, count: 12)
    for i in 0..<8 { bytes[4 + i] = UInt8(counter >> UInt64(56 - 8 * i) & 0xFF) }
    // 12 bytes is always a valid ChaChaPoly nonce.
    return try! ChaChaPoly.Nonce(data: bytes)
}

enum Direction {
    static let remoteToHub = "multicast remote→hub"
    static let hubToRemote = "multicast hub→remote"
}
