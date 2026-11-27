import Foundation
import MulticastHubModel
import os

/// What the hub remembers across launches.
public struct HubSettings: Codable, Equatable, Sendable {
    /// Per-speaker preset, keyed by speaker id.
    public struct SpeakerPreset: Codable, Equatable, Sendable {
        public var volume: Double
        public var syncTrimMs: Int
        public var isEnabled: Bool
        /// The speaker's loudness has been handed to its device's own volume (a Mac output whose
        /// slider is that output's volume): `volume` is not in effect as a gain. False for a
        /// preset saved before that existed, whose `volume` was a gain on top of the device's
        /// volume and is folded into the device once (see `LocalHub`, "Device-volume speakers").
        public var volumeHandedToDevice: Bool

        public init(volume: Double, syncTrimMs: Int = 0, isEnabled: Bool = false, volumeHandedToDevice: Bool = false) {
            self.volume = volume
            self.syncTrimMs = syncTrimMs
            self.isEnabled = isEnabled
            self.volumeHandedToDevice = volumeHandedToDevice
        }

        private enum CodingKeys: String, CodingKey { case volume, syncTrimMs, isEnabled, volumeHandedToDevice }

        /// Presets saved before a field existed still load (the field takes its default).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            volume = try c.decode(Double.self, forKey: .volume)
            syncTrimMs = try c.decode(Int.self, forKey: .syncTrimMs)
            isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
            volumeHandedToDevice = try c.decodeIfPresent(Bool.self, forKey: .volumeHandedToDevice) ?? false
        }
    }

    public var masterVolume: Double
    public var speakers: [String: SpeakerPreset]

    /// Pinned playlists, in pin order.
    public var pins: [PinnedPlaylist]

    public init(masterVolume: Double = 0.6, speakers: [String: SpeakerPreset] = [:], pins: [PinnedPlaylist] = []) {
        self.masterVolume = masterVolume
        self.speakers = speakers
        self.pins = pins
    }

    private enum CodingKeys: String, CodingKey { case masterVolume, speakers, pins }

    /// Settings saved before a field existed still load (the field takes its default).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterVolume = try c.decode(Double.self, forKey: .masterVolume)
        speakers = try c.decode([String: SpeakerPreset].self, forKey: .speakers)
        pins = try c.decodeIfPresent([PinnedPlaylist].self, forKey: .pins) ?? []
    }
}

/// Where `HubSettings` live. A protocol so tests can inject an in-memory store.
public protocol HubSettingsStore: Sendable {
    func load() -> HubSettings
    func save(_ settings: HubSettings)
}

/// `UserDefaults`, one JSON blob under one key (so a schema change never leaves half a state).
public final class UserDefaultsSettingsStore: HubSettingsStore, @unchecked Sendable {
    public static let defaultKey = "MulticastHub.settings.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> HubSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(HubSettings.self, from: data) else { return HubSettings() }
        return settings
    }

    public func save(_ settings: HubSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Keeps settings in memory only (tests, live checks that must not touch the user's defaults).
public final class InMemorySettingsStore: HubSettingsStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<HubSettings>(initialState: HubSettings())
    public private(set) var saveCount: Int {
        get { counter.withLock { $0 } }
        set { counter.withLock { $0 = newValue } }
    }
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    public init(_ initial: HubSettings = HubSettings()) {
        lock.withLock { $0 = initial }
    }

    public func load() -> HubSettings { lock.withLock { $0 } }

    public func save(_ settings: HubSettings) {
        lock.withLock { $0 = settings }
        counter.withLock { $0 += 1 }
    }
}
