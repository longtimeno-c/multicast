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

        public init(volume: Double, syncTrimMs: Int = 0, isEnabled: Bool = false) {
            self.volume = volume
            self.syncTrimMs = syncTrimMs
            self.isEnabled = isEnabled
        }
    }

    public var masterVolume: Double
    public var speakers: [String: SpeakerPreset]

    public init(masterVolume: Double = 0.6, speakers: [String: SpeakerPreset] = [:]) {
        self.masterVolume = masterVolume
        self.speakers = speakers
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
