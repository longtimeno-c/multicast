import Foundation
import MulticastCalibration
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
    ///
    /// 2: the hub's play queue (`QueueItem`, `HubState.queue`, queue commands, Up Next answered
    /// with `.queue`), pinned playlists and `playPlaylist(id:shuffled:)`. Version 1 builds can't
    /// decode version 2 states and vice versa, so neither is spoken across.
    ///
    /// 3: Apple Music catalog search (`HubQuery.catalogSearch`, `TrackContext.catalog`). States
    /// are unchanged, so version 2 is still spoken: a remote on a version 2 link never sends the
    /// two new forms (a version 2 hub can't decode them and would drop the link) and answers
    /// catalog search with `.unsupported` itself.
    ///
    /// 4: a paired iPhone as a speaker (`ClientMessage.speakerOffer` and friends,
    /// `HubMessage.speakerAccepted`, `SpeakerTransport.phone`, `SpeakerGlyph.phone`, and the UDP
    /// audio channel in Audio/AudioWire.swift). Older versions are still spoken: the new messages
    /// are never sent on such a link, and the hub shows an older remote a phone speaker as a
    /// built-in one (`HubState.downgraded(forRemoteVersion:)`).
    ///
    /// 5: a phone that is a speaker applies its speaker volume (`SpeakerItem.volume` of its own
    /// row) to its system volume, and reports its system volume with `setSpeakerVolume`. For
    /// such a phone the hub sends the master volume alone in the audio channel's volume field.
    /// No message changed, so version 4 is still spoken both ways: a version 4 phone gets its
    /// whole volume in that field as before, and a phone on a version 4 hub leaves its system
    /// volume alone.
    ///
    /// 6: a paired iPhone as the microphone of a sync calibration (`ClientMessage.tuneSpeaker`,
    /// `HubMessage.microphoneRequest` answered with `ClientMessage.microphoneAnswer`), and
    /// `HubCommand.calibrateSpeakerSync` / `calibrateSync` / `cancelSyncCalibration`. States
    /// only gained optional keys, so version 5 is still spoken both ways: the new messages and
    /// commands are never sent on such a link.
    public static let currentVersion = 6
    /// The first version in which a remote can tune speakers and lend its microphone.
    public static let calibrationVersion = 6
    /// The first version in which a phone speaker's volume is the phone's system volume.
    public static let phoneSystemVolumeVersion = 5
    /// The first version in which a remote can offer itself as a speaker.
    public static let phoneSpeakerVersion = 4
    /// The first version with catalog search.
    public static let catalogSearchVersion = 3
    /// The oldest protocol version this build still speaks.
    public static let oldestVersion = 2
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
    // Version 4 and later only:
    /// "Play on this iPhone": answered with `HubMessage.speakerAccepted` or a `commandResult`
    /// carrying the refusal. Offering again replaces the earlier offer.
    case speakerOffer(id: UInt64, route: PhoneRoute)
    /// The phone's output changed (a Bluetooth speaker connected or left).
    case speakerRoute(route: PhoneRoute)
    case speakerWithdraw
    // Version 6 and later only:
    /// "Tune this speaker, listening with my microphone": answered with a `commandResult` once
    /// the tuning has begun (or was refused). Its progress is `HubState.calibration`.
    case tuneSpeaker(id: UInt64, speakerID: SpeakerID)
    /// The answer to `HubMessage.microphoneRequest` `id`.
    case microphoneAnswer(id: UInt64, answer: MicrophoneAnswer)
}

/// What the hub asks of a phone that is the microphone of a calibration. Times are on the
/// PHONE's monotonic clock (`HostClock` there): the hub converts, using `.clock` exchanges.
enum MicrophoneRequest: Codable, Sendable, Equatable {
    case access(ask: Bool)
    case start
    case stop
    /// "What time is it on your clock?" One NTP-style exchange.
    case clock
    /// Look for `signal` in what you heard for `seconds` from `fromNanos`.
    case listen(signal: CalibrationSignal, fromNanos: UInt64, seconds: Double)
}

enum MicrophoneAnswer: Codable, Sendable, Equatable {
    case access(MicrophoneAccess)
    /// `error` nil: listening.
    case started(error: String?)
    case stopped
    /// The phone's clock when the request arrived and when this answer left.
    case clock(receivedNanos: UInt64, sentNanos: UInt64)
    /// nil: that stretch isn't on record. Never audio: only when the sweep arrived, how
    /// clearly, and a small picture of the search.
    case heard(HeardSweep?)
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
    /// Version 4 and later only: the offer `id` was taken. The audio channel is UDP `port` on
    /// the hub's address, keyed with `salt` (see Audio/AudioWire.swift); `speakerID` is the
    /// phone's own row in `HubState.speakers`.
    case speakerAccepted(id: UInt64, port: UInt16, salt: Data, speakerID: String)
    /// Version 6 and later only, and only to a remote that asked to tune a speaker: answered
    /// with `ClientMessage.microphoneAnswer` carrying the same `id`.
    case microphoneRequest(id: UInt64, request: MicrophoneRequest)
}

extension HubState {
    /// The state as a remote speaking `version` can decode it: before version 4 there is no
    /// phone transport or glyph, so a phone speaker is shown as a built-in, portable one.
    func downgraded(forRemoteVersion version: Int) -> HubState {
        guard version < RemoteProtocol.phoneSpeakerVersion, speakers.contains(where: { $0.transport == .phone || $0.glyph == .phone })
        else { return self }
        var s = self
        s.speakers = speakers.map {
            var item = $0
            if item.transport == .phone { item.transport = .builtIn }
            if item.glyph == .phone { item.glyph = .portable }
            return item
        }
        return s
    }
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
