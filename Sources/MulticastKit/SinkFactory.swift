import Foundation
import MulticastAudio
import MulticastRAOP
import MulticastLocalOutput

/// Builds the right `AudioSink` for a speaker. A protocol so apps and tests can substitute it.
public protocol SinkProviding: Sendable {
    func makeSink(for speaker: SpeakerDescriptor) throws -> AudioSink
}

public enum SinkFactoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingNetworkAddress(speaker: String)
    case missingDeviceUID(speaker: String)

    public var description: String {
        switch self {
        case .missingNetworkAddress(let s): return "\(s) has no resolved host/port yet"
        case .missingDeviceUID(let s): return "\(s) has no Core Audio device UID"
        }
    }
}

/// The default factory: `RAOPSink` for AirPlay 1 and AirPlay 2 speakers (AirPlay 2 devices are
/// driven over the legacy RAOP path after `POST /auth-setup`), `LocalOutputSink` for local outputs
/// (on iOS: the current audio route).
public struct SinkFactory: SinkProviding {
    public enum Kind: String, Codable, Sendable, Equatable { case raop, local }

    /// Options passed to every `RAOPSink` (logging, timeouts, user agent…).
    public var raopOptions: RAOPSink.Options
    /// Per-speaker AirPlay passwords, keyed by `SpeakerDescriptor.id`.
    public var passwords: [String: String]

    public init(raopOptions: RAOPSink.Options = .init(), passwords: [String: String] = [:]) {
        self.raopOptions = raopOptions
        self.passwords = passwords
    }

    /// Which sink type a descriptor maps to (pure).
    public static func kind(for speaker: SpeakerDescriptor) -> Kind {
        switch speaker.transport {
        case .airplay1, .airplay2: return .raop
        case .local: return .local
        }
    }

    public func makeSink(for speaker: SpeakerDescriptor) throws -> AudioSink {
        switch SinkFactory.kind(for: speaker) {
        case .raop:
            guard speaker.host?.isEmpty == false, speaker.port != nil else {
                throw SinkFactoryError.missingNetworkAddress(speaker: speaker.name)
            }
            var options = raopOptions
            if let pw = passwords[speaker.id] { options.password = pw }
            return RAOPSink(descriptor: speaker, options: options)
        case .local:
            #if os(macOS)
            guard speaker.localDeviceUID != nil else { throw SinkFactoryError.missingDeviceUID(speaker: speaker.name) }
            return try LocalOutputSink(descriptor: speaker)
            #else
            return CurrentRouteSink(descriptor: speaker)
            #endif
        }
    }
}
