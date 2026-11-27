import Foundation
import MulticastAudio
import MulticastHubModel
import Network

/// Where "Play on this iPhone" stands, for the remote's UI.
public enum PhoneSpeakerPhase: Sendable, Equatable {
    /// Not offered.
    case off
    /// Wanted, but there is no connection to the Mac right now; offered again when there is.
    case waitingForHub
    /// Asking the Mac.
    case offering
    /// The Mac lists this device as a speaker; `speakerID` is its row in `HubState.speakers`.
    case on(speakerID: SpeakerID)
    /// The Mac's version of Multicast is too old.
    case unsupported(message: String)
    case failed(message: String)
}

/// This device as a speaker of the hub it is the remote of.
extension RemoteHubBackend {
    /// Offers this device to the Mac as a speaker, playing through `output`; `route` names what
    /// that output is right now. Call again with a new `route` when the output changes. The
    /// offer is kept across reconnects until `stopPhoneSpeaker()`.
    public func startPhoneSpeaker(route: PhoneRoute, output: any PhoneAudioOutput) {
        speaker.withLock { s in
            s.wanted = (route, output)
            s.generation += 1
        }
        Task { await reconcileSpeaker() }
    }

    public func stopPhoneSpeaker() {
        speaker.withLock { s in
            s.wanted = nil
            s.generation += 1
        }
        Task { await reconcileSpeaker() }
    }

    public var phoneSpeakerPhase: PhoneSpeakerPhase { speakerBroadcast.latest ?? .off }

    /// The phase now, then every change.
    public func phoneSpeakerPhases() -> AsyncStream<PhoneSpeakerPhase> { speakerBroadcast.stream() }

    /// Clock, buffer and loss figures; nil unless the phase is `.on`.
    public var phoneSpeakerStats: PhoneSpeakerStats? { speaker.value.client?.stats }

    /// The app closed the output itself (an interruption began): it is started again when the
    /// output says it may.
    public func phoneSpeakerOutputStopped() { speaker.value.client?.outputStopped() }

    /// The session came or went.
    func speakerSessionChanged() {
        speaker.withLock { $0.generation += 1 }
        Task { await reconcileSpeaker() }
    }

    private func setSpeakerPhase(_ phase: PhoneSpeakerPhase) {
        if speakerBroadcast.latest != phase { speakerBroadcast.yield(phase) }
    }

    /// Brings the channel in line with what is wanted and what is connected. One at a time;
    /// repeats until nothing changed while it worked.
    private func reconcileSpeaker() async {
        await speakerMutex.lock()
        while true {
            let seen = speaker.value.generation
            await reconcileSpeakerOnce()
            if speaker.value.generation == seen { break }
        }
        await speakerMutex.unlock()
    }

    private func reconcileSpeakerOnce() async {
        let session = currentSession
        let state = speaker.value
        // Close a channel that is no longer wanted or belongs to a session that has ended.
        if let client = state.client, state.wanted == nil || session == nil || state.clientSession !== session {
            client.stop()
            speaker.withLock { s in
                s.client = nil
                s.clientSession = nil
                s.sentRoute = nil
            }
            if state.wanted == nil, let session, state.clientSession === session { session.post(.speakerWithdraw) }
        }
        guard let wanted = state.wanted else {
            setSpeakerPhase(.off)
            return
        }
        guard let session, !session.hasEnded else {
            setSpeakerPhase(.waitingForHub)
            return
        }
        guard session.info.version >= RemoteProtocol.phoneSpeakerVersion else {
            setSpeakerPhase(.unsupported(message: "Update Multicast on the Mac to play on this \(configuration.deviceKind)."))
            return
        }
        if speaker.value.client != nil {
            if speaker.value.sentRoute != wanted.route {
                session.post(.speakerRoute(route: wanted.route))
                speaker.withLock { $0.sentRoute = wanted.route }
            }
            return
        }
        setSpeakerPhase(.offering)
        do {
            switch try await session.request({ .speakerOffer(id: $0, route: wanted.route) }) {
            case .speaker(let port, let salt, let speakerID):
                guard let host = session.hubHost, let keys = session.audioChannelKeys(salt: salt),
                      salt.count == AudioChannel.saltLength, port != 0 else {
                    setSpeakerPhase(.failed(message: "Couldn\u{2019}t open the audio channel to the Mac."))
                    return
                }
                let client = PhoneSpeakerClient(host: host, port: port, keys: keys, output: wanted.output)
                speaker.withLock { s in
                    s.client = client
                    s.clientSession = session
                    s.sentRoute = wanted.route
                }
                client.start()
                setSpeakerPhase(.on(speakerID: SpeakerID(speakerID)))
            case .command(let error?):
                setSpeakerPhase(error.code == .unsupported ? .unsupported(message: error.message) : .failed(message: error.message))
            default:
                setSpeakerPhase(.failed(message: "Unexpected answer from the Mac."))
            }
        } catch {
            // The session ended meanwhile: offered again with the next one.
            setSpeakerPhase(.waitingForHub)
        }
    }
}

/// `RemoteHubBackend`'s speaker state (kept here so the extension above has it all in view).
struct PhoneSpeakerState {
    var wanted: (route: PhoneRoute, output: any PhoneAudioOutput)?
    var generation = 0
    var client: PhoneSpeakerClient?
    var clientSession: RemoteSession?
    var sentRoute: PhoneRoute?
}
