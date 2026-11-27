// swift-tools-version: 6.0
import PackageDescription

// Multicast — one audio stream, fanned out in sync to AirPlay 1, AirPlay 2 and local/Bluetooth speakers.
//
// Module map (each module depends ONLY on MulticastAudio, the frozen contract layer):
//   MulticastAudio        contracts: PCM format, timeline, AudioSource, AudioSink, SpeakerDescriptor
//   MulticastDiscovery    Bonjour discovery of AirPlay 1/2 speakers
//   MulticastRAOP         RAOP (AirPlay audio) sender, one sink per network speaker
//   MulticastLocalOutput  Core Audio outputs (built-in, Bluetooth, USB…) as timeline-aligned sinks
//   MulticastSources      tone, file and (macOS) app/system audio capture sources
//   MulticastEngine       pacing clock + fan-out from one source to many sinks
//   MulticastCalibration  sync calibration: the test sweep, finding it in a recording, trims
//   MulticastKit          umbrella that wires everything together for the apps
//
// App-facing layer (the Mac hub app and the iOS remote):
//   MulticastHubModel     UI-facing value types, HubState, HubCommand/HubQuery and the HubBackend
//                         protocol; no dependencies, so the iOS remote shares it
//   MulticastHub          the Mac hub: HubBackend over MulticastKit, serves remotes
//   MulticastRemote       the iOS remote: HubBackend as a network client of the hub
//   MulticastAppleMusic   the hub's own Apple Music player (library, playlists, search, queue)
let package = Package(
    name: "Multicast",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MulticastKit", targets: ["MulticastKit"]),
        .library(name: "MulticastHubModel", targets: ["MulticastHubModel"]),
        .library(name: "MulticastHub", targets: ["MulticastHub"]),
        .library(name: "MulticastRemote", targets: ["MulticastRemote"]),
        .library(name: "MulticastAppleMusic", targets: ["MulticastAppleMusic"]),
        .executable(name: "multicast-cli", targets: ["multicast-cli"]),
        .executable(name: "raop-probe", targets: ["raop-probe"]),
        .executable(name: "multicast-remote-cli", targets: ["multicast-remote-cli"]),
        .executable(name: "multicast-hub", targets: ["multicast-hub"]),
    ],
    targets: [
        .target(name: "MulticastAudio"),
        .target(name: "MulticastDiscovery", dependencies: ["MulticastAudio"]),
        .target(name: "MulticastRAOP", dependencies: ["MulticastAudio"]),
        .target(name: "MulticastLocalOutput", dependencies: ["MulticastAudio"]),
        .target(name: "MulticastSources", dependencies: ["MulticastAudio"]),
        .target(name: "MulticastEngine", dependencies: ["MulticastAudio"]),
        // Sync calibration's arithmetic: the test sound, finding it in a recording, trims.
        .target(name: "MulticastCalibration", dependencies: ["MulticastAudio"]),
        .target(
            name: "MulticastKit",
            dependencies: [
                "MulticastAudio", "MulticastDiscovery", "MulticastRAOP",
                "MulticastLocalOutput", "MulticastSources", "MulticastEngine",
            ]
        ),
        .target(name: "MulticastHubModel"),
        // The pure parts of the output device driver (Drivers/MulticastDevice), for the tests.
        .target(name: "MulticastDeviceCore", path: "Drivers/MulticastDevice/Core"),
        .target(name: "MulticastHub", dependencies: ["MulticastKit", "MulticastHubModel", "MulticastAppleMusic", "MulticastCalibration"]),
        .target(name: "MulticastRemote", dependencies: ["MulticastHubModel", "MulticastAudio", "MulticastCalibration"]),
        .target(name: "MulticastAppleMusic", dependencies: ["MulticastHubModel", "MulticastSources", "MulticastAudio"]),
        .executableTarget(name: "multicast-cli", dependencies: ["MulticastKit"]),
        .executableTarget(name: "multicast-hub", dependencies: ["MulticastHub", "MulticastRemote", "MulticastAppleMusic", "MulticastHubModel"]),
        .executableTarget(name: "multicast-remote-cli", dependencies: ["MulticastRemote", "MulticastHubModel"]),
        .executableTarget(name: "raop-probe", dependencies: ["MulticastAudio", "MulticastRAOP"]),
        .testTarget(name: "MulticastDiscoveryTests", dependencies: ["MulticastDiscovery"]),
        .testTarget(name: "MulticastRAOPTests", dependencies: ["MulticastRAOP"]),
        .testTarget(name: "MulticastLocalOutputTests", dependencies: ["MulticastLocalOutput"]),
        .testTarget(name: "MulticastSourcesTests", dependencies: ["MulticastSources"]),
        .testTarget(name: "MulticastEngineTests", dependencies: ["MulticastEngine"]),
        .testTarget(name: "MulticastKitTests", dependencies: ["MulticastKit"]),
        .testTarget(name: "MulticastCalibrationTests", dependencies: ["MulticastCalibration"]),
        .testTarget(name: "MulticastAudioTests", dependencies: ["MulticastAudio"]),
        .testTarget(name: "MulticastHubModelTests", dependencies: ["MulticastHubModel"]),
        .testTarget(name: "MulticastHubTests", dependencies: ["MulticastHub", "MulticastAppleMusic", "MulticastCalibration"]),
        .testTarget(name: "MulticastRemoteTests", dependencies: ["MulticastRemote", "MulticastCalibration"]),
        .testTarget(name: "MulticastDeviceCoreTests", dependencies: ["MulticastDeviceCore"]),
        .testTarget(name: "MulticastAppleMusicTests", dependencies: ["MulticastAppleMusic"]),
    ],
    swiftLanguageModes: [.v5]
)
