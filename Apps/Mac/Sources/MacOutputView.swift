import MulticastHubModel
import SwiftUI

/// The "Mac output" source: plays whatever the Mac sends to the "Multicast" output device.
struct MacOutputView: View {
    @Environment(HubModel.self) private var model

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: MC.Space.m) {
                HStack(spacing: MC.Space.m) {
                    Image(systemName: SourceKind.macOutput.symbolName)
                        .font(.system(size: 28))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(MC.Ink.secondary)
                    VStack(alignment: .leading, spacing: MC.Space.xxs) {
                        Text("Mac output")
                            .font(MC.Font.title)
                            .foregroundStyle(MC.Ink.primary)
                        HStack(spacing: MC.Space.xs) {
                            if isLive { Circle().fill(MC.Status.playing).frame(width: 6, height: 6) }
                            Text(isLive ? (model.nowPlaying?.artist ?? "Playing") : "Not playing")
                        }
                        .font(MC.Font.caption)
                        .foregroundStyle(MC.Ink.secondary)
                    }
                }
                Text("Choose \u{201C}Multicast\u{201D} as the output in System Settings \u{203A} Sound, or in any app that has an output menu. Everything the Mac plays there goes to your speakers, in sync. The Mac\u{2019}s own speakers stay quiet unless you turn them on here as a speaker.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.body)
                    .lineLimit(nil)
                HStack(spacing: MC.Space.s) {
                    if !isLive {
                        Button("Play Mac output") { model.selectSource(.macOutput) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Sound Settings\u{2026}") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Text("Needs the Multicast output device (Drivers/MulticastDevice) and Microphone access, which reading it requires.")
                    .font(MC.Font.caption)
                    .foregroundStyle(MC.Ink.secondary)
                    .lineLimit(nil)
            }
            .selectionDisabled()
            .sourceRow()
        }
        .sourceList()
    }

    private var isLive: Bool { model.activeSource == .macOutput && model.transport.isPlaying }
}
