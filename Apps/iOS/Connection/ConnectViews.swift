import SwiftUI
import MulticastHubModel

/// Everything before the hub screens: choosing the Mac, pairing, and the calm states for a Mac
/// that can't be found or reached. One stack, so each step replaces the last in place.
struct ConnectFlowView: View {
    @Environment(RemoteSession.self) private var session

    var body: some View {
        NavigationStack {
            Group {
                switch session.link {
                case .searching:
                    if session.searchTimedOut && session.hubs.isEmpty {
                        HubNotFoundView()
                    } else {
                        HubPickerView()
                    }
                case .connecting(let hub):
                    ConnectingView(hub: hub)
                case .pairing(let hub, let prompt):
                    PairingView(hub: hub, prompt: prompt)
                case .lost(let hub, let reason):
                    HubUnreachableView(hub: hub, reason: reason)
                case .connected(let hub, _):
                    ConnectingView(hub: hub)
                }
            }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MC.Surface.canvas)
        }
    }
}

// MARK: - Choosing a Mac

private struct HubPickerView: View {
    @Environment(RemoteSession.self) private var session

    var body: some View {
        List {
            Section {
                if session.hubs.isEmpty {
                    HStack(spacing: MC.Space.m) {
                        ProgressView()
                            .frame(width: 28)
                        Text("Looking for your Mac\u{2026}")
                            .font(MC.Font.body)
                            .foregroundStyle(MC.Ink.secondary)
                    }
                    .frame(minHeight: 44)
                    .transition(.opacity)
                } else {
                    ForEach(session.hubs) { hub in
                        Button { session.connect(hub) } label: { HubRow(hub: hub) }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            } header: {
                Text("Macs on this network")
            } footer: {
                Text("Open Multicast on the Mac that plays your music. It shows up here when your iPhone is on the same Wi\u{2011}Fi.")
            }
            .listRowBackground(Rectangle().fill(MC.Surface.group))

            Section {
                Button { session.navigation.showsPhoneOnly = true } label: { PhoneOnlyRow() }
            } header: {
                Text("No Mac?")
            } footer: {
                Text("Experimental. Plays what this iPhone is playing on your AirPlay speakers, about 2 seconds late.")
            }
            .listRowBackground(Rectangle().fill(MC.Surface.group))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Connect")
    }
}

/// The way into iPhone Only mode from the list of Macs.
private struct PhoneOnlyRow: View {
    var body: some View {
        HStack(spacing: MC.Space.m) {
            Image(systemName: "iphone")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(MC.Ink.body)
                .frame(width: 28)
            Text("Use iPhone Only")
                .font(MC.Font.body)
                .foregroundStyle(MC.Ink.primary)
            Spacer(minLength: MC.Space.s)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MC.Ink.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Use iPhone Only, experimental")
        .accessibilityHint("Plays this iPhone\u{2019}s sound on AirPlay speakers without a Mac")
        .accessibilityAddTraits(.isButton)
    }
}

private struct HubRow: View {
    var hub: DiscoveredHub

    var body: some View {
        HStack(spacing: MC.Space.m) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(MC.Ink.body)
                .frame(width: 28)
            Text(hub.name)
                .font(MC.Font.body)
                .foregroundStyle(MC.Ink.primary)
            Spacer(minLength: MC.Space.s)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MC.Ink.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hub.name)
        .accessibilityHint("Connects to this Mac")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Can't find / can't reach

private struct HubNotFoundView: View {
    @Environment(RemoteSession.self) private var session

    var body: some View {
        ContentUnavailableView {
            Label("Can\u{2019}t Find Your Mac", systemImage: "desktopcomputer")
        } description: {
            VStack(alignment: .leading, spacing: MC.Space.m) {
                Text("Nothing has answered yet. Check these, then try again:")
                    .foregroundStyle(MC.Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CheckItem(symbol: "desktopcomputer", text: "Multicast is open on your Mac.")
                CheckItem(symbol: "wifi", text: "Your iPhone and Mac are on the same Wi\u{2011}Fi network.")
                CheckItem(symbol: "network", text: "Local Network is on for Multicast Remote in Settings.")
            }
            .multilineTextAlignment(.leading)
            .padding(.top, MC.Space.xs)
        } actions: {
            VStack(spacing: MC.Space.m) {
                Button("Try Again") { session.searchAgain() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Use iPhone Only (Experimental)") { session.navigation.showsPhoneOnly = true }
            }
        }
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CheckItem: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MC.Space.m) {
            // One weight and rendering for all three, scaling with the text beside them.
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .symbolVariant(.none)
                .font(.body)
                .foregroundStyle(MC.Ink.secondary)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(MC.Ink.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HubUnreachableView: View {
    @Environment(RemoteSession.self) private var session
    var hub: DiscoveredHub?
    var reason: String

    var body: some View {
        ContentUnavailableView {
            Label(hub.map { "Can\u{2019}t Reach \($0.name)" } ?? "Can\u{2019}t Reach Your Mac", systemImage: "desktopcomputer")
        } description: {
            Text("\(reason) Check that the Mac is awake and Multicast is open.")
        } actions: {
            VStack(spacing: MC.Space.m) {
                Button("Try Again") { session.reconnect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Choose Another Mac") { session.cancelPairing() }
            }
        }
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConnectingView: View {
    var hub: DiscoveredHub

    var body: some View {
        VStack(spacing: MC.Space.m) {
            ProgressView()
            Text("Connecting to \(hub.name)\u{2026}")
                .font(MC.Font.body)
                .foregroundStyle(MC.Ink.secondary)
        }
        .accessibilityElement(children: .combine)
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Pairing

/// First time only: the Mac shows a six-digit code and this phone types it. The field is one
/// real text field (number pad, one-time-code content type, so it accepts a pasted code);
/// the boxes are how it draws its digits.
private struct PairingView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var hub: DiscoveredHub
    var prompt: PairingPrompt

    @State private var code = ""
    @FocusState private var focused: Bool
    @State private var shake: CGFloat = 0

    /// Every edit, typed or pasted: digits only, at most the code's length, sent when complete.
    private func enter(_ text: String) {
        let digits = String(text.filter(\.isNumber).prefix(prompt.codeLength))
        code = digits
        if digits.count == prompt.codeLength, !session.isSubmittingCode {
            session.submit(code: digits)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MC.Space.s) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(MC.Ink.body)
                    .padding(.bottom, MC.Space.s)
                    .accessibilityHidden(true)
                Text("Enter the code shown on \(hub.name)")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(MC.Ink.primary)
                    .multilineTextAlignment(.center)
                Text("Multicast on your Mac shows a \(prompt.codeLength)-digit code the first time this iPhone connects.")
                    .font(MC.Font.body)
                    .foregroundStyle(MC.Ink.secondary)
                    .multilineTextAlignment(.center)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .padding(.horizontal, MC.Space.xxl)
            .padding(.top, MC.Space.xxxl)
            .padding(.bottom, MC.Space.l)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        // The field and its answer ride on the bottom safe area, so the keyboard lifts them
        // and they stay in view at any text size; the explanation scrolls above.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: MC.Space.l) {
                ZStack {
                    TextField("Pairing code", text: Binding(get: { code }, set: enter))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .opacity(0.02)
                        .frame(width: 1, height: 1)
                        .accessibilityLabel("Pairing code")
                        .accessibilityValue(code.isEmpty ? "Empty" : code.map(String.init).joined(separator: " "))
                    CodeBoxes(code: code, length: prompt.codeLength, isFocused: focused)
                        .offset(x: shake)
                        .onTapGesture { focused = true }
                        .accessibilityHidden(true)
                }

                ZStack {
                    if session.isSubmittingCode {
                        ProgressView()
                            .transition(.opacity)
                    } else if let failure = prompt.failure {
                        Text(failure)
                            .font(MC.Font.caption)
                            .foregroundStyle(MC.Status.failed)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: 44, alignment: .top)
                .animation(MC.Motion.feedback, value: session.isSubmittingCode)
            }
            .padding(.horizontal, MC.Space.xxl)
            .padding(.top, MC.Space.m)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .background(MC.Surface.canvas)
        }
        .scrollDismissesKeyboard(.never)
        .navigationTitle("Pair")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { session.cancelPairing() }
            }
        }
        .onAppear { focused = true }
        // A refused code: clear it and shake the boxes once, caused by the hub's answer.
        .onChange(of: prompt.attempt) { _, _ in
            code = ""
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.2)) { shake = 10 }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.1)) { shake = 0 }
        }
        .sensoryFeedback(.error, trigger: prompt.attempt)
    }
}

private struct CodeBoxes: View {
    var code: String
    var length: Int
    var isFocused: Bool
    @ScaledMetric(relativeTo: .title) private var boxHeight: CGFloat = 56

    var body: some View {
        let digits = Array(code)
        HStack(spacing: MC.Space.s) {
            ForEach(0..<length, id: \.self) { i in
                let isNext = isFocused && i == digits.count
                // The Mac shows the code as two groups of three: the boxes keep that chunking.
                if length == 6 && i == 3 { Color.clear.frame(width: MC.Space.m, height: 1) }
                RoundedRectangle(cornerRadius: MC.Radius.large - 2, style: .continuous)
                    .fill(MC.Surface.group)
                    .overlay {
                        RoundedRectangle(cornerRadius: MC.Radius.large - 2, style: .continuous)
                            .strokeBorder(isNext ? AnyShapeStyle(MC.accent) : AnyShapeStyle(Color.clear), lineWidth: 2)
                    }
                    .overlay {
                        if i < digits.count {
                            Text(String(digits[i]))
                                .font(.title.weight(.regular).monospacedDigit())
                                .foregroundStyle(MC.Ink.primary)
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .frame(maxWidth: 48)
                    .frame(height: boxHeight)
            }
        }
        .animation(MC.Motion.feedback, value: code)
    }
}
