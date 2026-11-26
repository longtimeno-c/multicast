import Foundation
import MulticastHubModel

// MARK: - Protocol constants
//
// The link between a Mac hub and its remotes, over TCP:
//
//   frame      := length:u32be payload[length]          (length 1…limit, checked before reading)
//
// Handshake phase (plaintext JSON payloads):
//   remote → hub   Hello                                 (always the first frame; see below)
//   hub → remote   HandshakeMessage …                    (challenge, pairing rounds, or a refusal)
//
// Session phase (after mutual authentication), every payload is sealed with ChaCha20-Poly1305
// under a per-direction key with an implicit 64-bit counter nonce:
//   sealed payload := kind:u8 body
//     kind 1  JSON `ClientMessage` (remote → hub) or `HubMessage` (hub → remote)
//     kind 2  artwork answer: requestID:u64be found:u8 bytes…   (hub → remote only)
//
// Frozen across protocol versions so that any two builds can tell each other to update: the
// frame header, `Hello.magic`/`minVersion`/`maxVersion`, and `HandshakeMessage.refused`.

public enum RemoteProtocol {
    /// The newest protocol version this build speaks.
    public static let currentVersion = 1
    /// The oldest protocol version this build still speaks.
    public static let oldestVersion = 1
    public static var supportedVersions: ClosedRange<Int> { oldestVersion...currentVersion }

    static let magic = "multicast-hub-link"

    /// Largest plaintext frame accepted before authentication (handshake and pairing).
    public static let maxHandshakeFrame = 16 * 1024
    /// Largest frame a hub accepts from an authenticated remote (commands and queries are small).
    public static let maxRemoteFrame = 256 * 1024
    /// Largest frame a remote accepts from the hub (pages of tracks, artwork).
    public static let maxHubFrame = 8 * 1024 * 1024

    /// Bonjour TXT keys.
    enum TXTKey {
        static let version = "v"
        static let hubID = "id"
        static let name = "n"
    }
}

// MARK: - Frames

enum FrameCodec {
    static let headerLength = 4

    static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: headerLength + payload.count)
        let n = UInt32(payload.count)
        out.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out.append(payload)
        return out
    }

    /// The payload length a header announces, validated against `limit` before anything else
    /// is read: a peer never makes us allocate more than we agreed to.
    static func payloadLength(header: Data, limit: Int) throws -> Int {
        guard header.count == headerLength else { throw RemoteLinkError.malformed("short frame header") }
        let b = [UInt8](header)
        let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard n > 0 else { throw RemoteLinkError.malformed("empty frame") }
        guard n <= limit else { throw RemoteLinkError.frameTooLarge(length: n, limit: limit) }
        return n
    }
}

// MARK: - Version negotiation

public enum VersionNegotiation {
    /// The highest version both sides speak, or nil.
    public static func agree(_ a: ClosedRange<Int>, _ b: ClosedRange<Int>) -> Int? {
        let v = min(a.upperBound, b.upperBound)
        return v >= max(a.lowerBound, b.lowerBound) ? v : nil
    }

    /// What to tell the person when the versions don't overlap, from this side's point of view.
    /// `thisDevice` names this side ("iPhone", "Mac"), `otherDevice` the peer.
    public static func updateMessage(local: ClosedRange<Int>, peer: ClosedRange<Int>,
                                     thisDevice: String, otherDevice: String) -> String {
        if peer.upperBound < local.lowerBound {
            "Multicast on the \(otherDevice) is too old for this \(thisDevice). Update Multicast on the \(otherDevice)."
        } else {
            "This version of Multicast is too old for the \(otherDevice). Update Multicast on this \(thisDevice)."
        }
    }
}

// MARK: - Handshake messages (plaintext)

/// Read first, leniently, so any future Hello can still be answered with a version refusal.
struct HelloVersionProbe: Decodable {
    var magic: String
    var minVersion: Int
    var maxVersion: Int
}

/// The remote's first frame.
struct Hello: Codable, Sendable {
    enum Intent: Codable, Sendable {
        /// Start an authenticated session with an existing pairing key.
        case session(nonce: Data, ephemeralKey: Data)
        /// Pair with a code shown on the hub. `publicKey` is a fresh X25519 key for this attempt.
        case pair(publicKey: Data)
    }

    var magic: String = RemoteProtocol.magic
    var minVersion: Int
    var maxVersion: Int
    var remoteID: String
    var remoteName: String
    var intent: Intent
}

struct SessionChallenge: Codable, Sendable {
    var version: Int
    var hubID: String
    var hubName: String
    var nonce: Data
    var ephemeralKey: Data
    /// The hub's wall clock at sending, for the first clock-offset estimate.
    var hubTime: Date
    /// HMAC under the pairing key over the transcript: proves the hub holds the key.
    var mac: Data
}

struct PairReady: Codable, Sendable {
    var version: Int
    var hubID: String
    var hubName: String
    var publicKey: Data
}

/// A hub's deliberate "no", with a reason a person can read.
public struct HubRefusal: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case incompatibleVersion, notPaired, authenticationFailed
        case pairingLocked, pairingBusy, pairingFailed, pairingCancelled, pairingTimedOut
        case tooManyConnections, malformed, revoked, shuttingDown
    }

    public var code: Code
    public var message: String
    /// For `.pairingLocked`: seconds until pairing is possible again.
    public var retryAfter: TimeInterval?
    /// For `.incompatibleVersion`: what the hub speaks.
    public var hubMinVersion: Int?
    public var hubMaxVersion: Int?

    public init(_ code: Code, _ message: String, retryAfter: TimeInterval? = nil,
                hubMinVersion: Int? = nil, hubMaxVersion: Int? = nil) {
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
        self.hubMinVersion = hubMinVersion
        self.hubMaxVersion = hubMaxVersion
    }

    public var errorDescription: String? { message }
}

enum HandshakeMessage: Codable, Sendable {
    case sessionChallenge(SessionChallenge)                 // hub → remote
    case sessionProof(mac: Data)                            // remote → hub
    case sessionAccepted                                    // hub → remote; sealed frames follow
    case pairReady(PairReady)                               // hub → remote; the hub shows the code
    case pairCommit(index: Int, commitment: Data)           // both ways
    case pairReveal(index: Int, nonce: Data)                // both ways
    case pairConfirm(mac: Data)                             // both ways
    case refused(HubRefusal)                                // hub → remote, then close
}

enum WireJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RemoteLinkError.malformed("\(T.self)")
        }
    }
}

// MARK: - Session messages (sealed)

enum ClientMessage: Codable, Sendable, Equatable {
    case command(id: UInt64, command: HubCommand)
    case query(id: UInt64, query: HubQuery)
    case levels(subscribe: Bool)
    case ping(id: UInt64)
    case pong(id: UInt64)
    case bye
}

enum HubMessage: Codable, Sendable, Equatable {
    case state(HubState)
    case levels(StereoLevels)
    /// `error` nil means the command was accepted.
    case commandResult(id: UInt64, error: HubCommandError?)
    /// Exactly one of `result` and `error` is set. Artwork answers travel as binary payloads.
    case queryResult(id: UInt64, result: HubQueryResult?, error: HubCommandError?)
    case ping(id: UInt64)
    case pong(id: UInt64, hubTime: Date)
    case bye(reason: String)
    /// The Mac removed this remote's pairing. Sent only inside the authenticated, sealed
    /// session, so it is the one signal a remote may delete its key on (see `ClientHandshake`).
    case revoked(reason: String)
}

/// The plaintext inside a sealed frame.
enum SessionPayload: Equatable, Sendable {
    case json(Data)
    case artwork(requestID: UInt64, data: Data?)

    static let jsonKind: UInt8 = 1
    static let artworkKind: UInt8 = 2

    func encoded() -> Data {
        switch self {
        case .json(let body):
            var out = Data([Self.jsonKind])
            out.append(body)
            return out
        case .artwork(let id, let data):
            var out = Data([Self.artworkKind])
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(id >> UInt64(shift) & 0xFF)) }
            out.append(data == nil ? 0 : 1)
            if let data { out.append(data) }
            return out
        }
    }

    static func decode(_ raw: Data) throws -> SessionPayload {
        let b = [UInt8](raw)
        guard let kind = b.first else { throw RemoteLinkError.malformed("empty payload") }
        switch kind {
        case jsonKind:
            guard b.count > 1 else { throw RemoteLinkError.malformed("empty message") }
            return .json(Data(b[1...]))
        case artworkKind:
            guard b.count >= 10 else { throw RemoteLinkError.malformed("short artwork header") }
            let id = b[1...8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            switch b[9] {
            case 0:
                guard b.count == 10 else { throw RemoteLinkError.malformed("artwork bytes with no-artwork flag") }
                return .artwork(requestID: id, data: nil)
            case 1:
                return .artwork(requestID: id, data: Data(b[10...]))
            default:
                throw RemoteLinkError.malformed("artwork flag")
            }
        default:
            throw RemoteLinkError.malformed("payload kind \(kind)")
        }
    }
}
