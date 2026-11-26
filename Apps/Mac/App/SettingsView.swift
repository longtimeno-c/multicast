import SwiftUI
import MulticastAppleMusic
import MulticastRemote

enum SettingsKey {
    static let showMenuBarExtra = "showMenuBarExtra"
    static let groupLatency = "groupLatencyMs"
    static let appleMusicBackend = "appleMusicBackend"
}

struct SettingsView: View {
    @Environment(HubRuntime.self) private var runtime
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(SettingsKey.groupLatency) private var groupLatency = 2000
    @AppStorage(SettingsKey.appleMusicBackend) private var appleMusicBackend = AppleMusicBackendKind.musicApp.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Show speakers in the menu bar", isOn: $showMenuBarExtra)
            }
            Section {
                Picker("Buffer", selection: $groupLatency) {
                    Text("1 second").tag(1000)
                    Text("2 seconds").tag(2000)
                    Text("3 seconds").tag(3000)
                }
                Picker("Apple Music plays through", selection: $appleMusicBackend) {
                    Text("The Music app").tag(AppleMusicBackendKind.musicApp.rawValue)
                    Text("MusicKit (team-signed builds)").tag(AppleMusicBackendKind.musicKit.rawValue)
                }
            } footer: {
                Text("A longer buffer rides out a busy network, but play and skip take that long to be heard. Both settings apply the next time Multicast opens.")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
            }
            RemotesSection()
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The iPhones paired with this Mac, each removable. A removed iPhone is disconnected at once
/// and has to pair again with a new code.
private struct RemotesSection: View {
    @Environment(HubRuntime.self) private var runtime
    /// The remote whose Remove is waiting for confirmation.
    @State private var removing: PairedRemote?

    var body: some View {
        Section {
            if runtime.isMock {
                Text("Remotes connect to the real hub, not this preview.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.secondary)
            } else if let problem = runtime.remoteProblem {
                Text(problem)
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.secondary)
            } else if runtime.pairedRemotes.isEmpty {
                Text("No iPhone is paired yet. Open Multicast Remote on an iPhone on this network and choose \u{201C}\(runtime.hubName)\u{201D}.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.secondary)
                    .lineLimit(nil)
            } else {
                ForEach(runtime.pairedRemotes) { remote in
                    HStack(spacing: MC.Space.m) {
                        Image(systemName: "iphone")
                            .font(.system(size: 15))
                            .foregroundStyle(MC.Ink.secondary)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: MC.Space.xxs) {
                            Text(remote.name)
                                .font(MC.Font.body)
                                .foregroundStyle(MC.Ink.primary)
                            Text(remote.isConnected ? "Connected" : "Paired \(remote.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(MC.Font.caption)
                                .foregroundStyle(MC.Ink.secondary)
                        }
                        Spacer(minLength: MC.Space.m)
                        Button("Remove", role: .destructive) { removing = remote }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Remotes")
        }
        .confirmationDialog(removing.map { "Remove \u{201C}\($0.name)\u{201D}?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { remote in
            Button("Remove", role: .destructive) { runtime.revoke(remote) }
        } message: { _ in
            Text("It is disconnected now and will need a new code to connect again.")
        }
    }
}
