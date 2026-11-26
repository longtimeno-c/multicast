import MulticastHubModel
import SwiftUI

/// The "Mac output" source on the remote: plays whatever the Mac sends to its "Multicast" output.
struct MacOutputScreen: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        List {
            Section {
                Text("On the Mac, choose \u{201C}Multicast\u{201D} as the output in System Settings \u{203A} Sound or in an app. Everything played there goes to your speakers, in sync.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.body)
                    .listRowBackground(Color.clear)
                Button(isLive ? "Playing Mac output" : "Play Mac output") { model.selectSource(.macOutput) }
                    .disabled(isLive)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Mac Output")
    }

    private var isLive: Bool { model.activeSource == .macOutput && model.transport.isPlaying }
}
