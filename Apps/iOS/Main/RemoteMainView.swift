import SwiftUI
import MulticastHubModel

/// The hub screens. Two tabs, because there are two jobs: Speakers (where it plays, the reason
/// the app exists) and Music (what plays). The tab bar keeps Speakers one tap away from any
/// screen, and the full player's speakers button gets there in one tap too. Now playing rides
/// above the tab bar as the system's bottom accessory, so transport is reachable from
/// everywhere; tapping it opens the full player sheet.
struct RemoteMainView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: HubModel

    var body: some View {
        @Bindable var nav = session.navigation
        TabView(selection: $nav.tab) {
            SpeakersScreen()
                .legacyMiniPlayer()
                .tabItem { Label("Speakers", systemImage: "hifispeaker.2.fill") }
                .tag(RemoteNavigation.Tab.speakers)
            MusicScreen()
                .legacyMiniPlayer()
                .tabItem { Label("Music", systemImage: "music.note") }
                .tag(RemoteNavigation.Tab.music)
        }
        // The accessory has the system's fixed height; its words stop growing where they'd clip.
        .miniPlayerAccessory { MiniPlayer().dynamicTypeSize(...DynamicTypeSize.xxLarge) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = session.linkProblem {
                LinkBanner(message: problem, isReconnecting: session.isReconnecting, onRetry: session.reconnect)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(MC.Motion.state(reduceMotion), value: session.linkProblem)
        .sheet(isPresented: $nav.showsNowPlaying) {
            NowPlayingSheet()
                .environment(model)
                .environment(session)
        }
        .sheet(item: $nav.speakerDetail) { target in
            SpeakerDetailSheet(speakerID: target.id)
                .environment(model)
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        ), presenting: model.alert) { _ in
            Button("OK") { model.alert = nil }
        } message: { alert in
            Text(alert.message)
        }
        .environment(model)
        .onAppear { model.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, new in model.reduceMotion = new }
    }
}

/// The link is down or coming back: say so above everything, calmly, with the one action.
private struct LinkBanner: View {
    var message: String
    var isReconnecting: Bool
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: MC.Space.m) {
            ZStack {
                if isReconnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MC.Ink.body)
                }
            }
            .frame(width: 24)
            .accessibilityHidden(true)
            Text(message)
                .font(MC.Font.caption)
                .foregroundStyle(MC.Ink.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !isReconnecting {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .padding(.horizontal, MC.Space.l)
        .padding(.vertical, MC.Space.s)
        .frame(minHeight: 44)
        .background(MC.Surface.group)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Mini player placement

extension View {
    /// Now playing as the tab view's bottom accessory (iOS 26 and later).
    @ViewBuilder func miniPlayerAccessory<C: View>(@ViewBuilder _ content: @escaping () -> C) -> some View {
        if #available(iOS 26.0, *) {
            tabViewBottomAccessory(content: content)
        } else {
            self
        }
    }

    /// Before iOS 26 there is no accessory slot: each tab carries the mini player above its
    /// tab bar instead.
    @ViewBuilder func legacyMiniPlayer() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayer()
                    .padding(.vertical, MC.Space.s)
                    .background(.bar)
            }
        }
    }

    /// A bar pinned to the bottom of a scrolling screen, with the system's scroll edge
    /// treatment where it exists.
    @ViewBuilder func bottomBar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { content().background(.bar) }
        }
    }

    /// Content scrolling under the pinned master volume fades rather than stopping at a line.
    @ViewBuilder func softBottomEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }
}
