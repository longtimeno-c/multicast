import SwiftUI

enum SettingsKey {
    static let showMenuBarExtra = "showMenuBarExtra"
    static let groupLatency = "groupLatencyMs"
    static let keepSpeakersOn = "keepSpeakersOnWhenStopped"
}

struct SettingsView: View {
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(SettingsKey.groupLatency) private var groupLatency = 2000
    @AppStorage(SettingsKey.keepSpeakersOn) private var keepSpeakersOn = true

    var body: some View {
        Form {
            Section {
                Toggle("Show speakers in the menu bar", isOn: $showMenuBarExtra)
                Toggle("Keep speakers connected when playback stops", isOn: $keepSpeakersOn)
            }
            Section {
                Picker("Buffer", selection: $groupLatency) {
                    Text("1 second").tag(1000)
                    Text("2 seconds").tag(2000)
                    Text("3 seconds").tag(3000)
                }
            } footer: {
                Text("A longer buffer rides out a busy network, but play and skip take that long to be heard.")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
