import AVFoundation
import MediaPlayer
import UIKit

/// This device's system output volume: the one the side buttons and Control Centre move, and,
/// for a Bluetooth speaker that takes its volume from the phone, the speaker's own.
@MainActor
protocol PhoneSystemVolume: AnyObject {
    /// The volume now, 0…1, as iOS last reported it.
    var volume: Double { get }
    /// Called when the volume changed, whoever changed it.
    var onChange: ((Double) -> Void)? { get set }
    /// Asks iOS for this volume. `volume` follows when iOS says it has changed; on an output
    /// with a fixed volume, and in the Simulator, it does not.
    func set(_ volume: Double)
    /// Reads the volume again (iOS only reports changes while the audio session is active).
    func refresh()
    /// Whether `set` is going to be used (this device is a speaker right now). Off, the
    /// controller keeps nothing in the app's window.
    func setInUse(_ inUse: Bool)
}

/// The real one.
///
/// iOS has no call that sets the system volume. What it has is `MPVolumeView`, the system's own
/// volume slider, which sets it when its slider's value is set. While this device is a speaker
/// one is kept in the app's window, far outside the visible area and all but transparent, and
/// never shown: the row's own slider is the control. It has to be in a window to work, so it
/// is put back whenever the app comes to the front, and before each write if it has lost its
/// window. The window stays while the app plays in the background, so a volume set on the Mac
/// is expected to arrive with the screen locked too.
///
/// While it is in the window, iOS may not show its own volume overlay for the side buttons in
/// this app; the row's slider moves instead.
///
/// Changes made anywhere are followed by observing `AVAudioSession.outputVolume`.
@MainActor
final class SystemVolumeController: PhoneSystemVolume {
    private(set) var volume: Double
    var onChange: ((Double) -> Void)?

    private let view: MPVolumeView
    private var observation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    /// A write waiting for the view to have been in a window for a turn of the run loop.
    private var waiting: Double?
    private var inUse = false

    init() {
        let session = AVAudioSession.sharedInstance()
        volume = Double(session.outputVolume)
        view = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 240, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let new = change.newValue else { return }
            Task { @MainActor in self?.noticed(Double(new)) }
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.inUse { self.attach() }
                    self.refresh()
                }
            })
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func set(_ volume: Double) {
        guard inUse else { return }
        let v = min(1, max(0, volume))
        if waiting != nil {
            waiting = v
        } else if attach() {
            // Just put in a window: the slider takes a value from the next turn on.
            waiting = v
            Task { @MainActor [weak self] in
                guard let self, let v = self.waiting else { return }
                self.waiting = nil
                self.write(v)
            }
        } else {
            write(v)
        }
    }

    func setInUse(_ inUse: Bool) {
        self.inUse = inUse
        if inUse {
            attach()
        } else {
            waiting = nil
            view.removeFromSuperview()
        }
    }

    func refresh() {
        noticed(Double(AVAudioSession.sharedInstance().outputVolume))
    }

    private func noticed(_ new: Double) {
        guard new.isFinite, abs(new - volume) > 0.0005 else { return }
        volume = new
        onChange?(new)
    }

    private func write(_ v: Double) {
        // No slider: the Simulator, or no window to be in. Nothing happens and `volume` stays.
        guard view.window != nil, let slider = Self.slider(in: view) else { return }
        slider.setValue(Float(v), animated: false)
    }

    /// Puts the view in the app's window if it isn't in one. True if it was added just now.
    @discardableResult
    private func attach() -> Bool {
        guard view.window == nil else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return false }
        window.addSubview(view)
        return true
    }

    private static func slider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews {
            if let found = slider(in: sub) { return found }
        }
        return nil
    }
}

/// A volume nothing changes from outside (review scenes, previews).
@MainActor
final class FixedSystemVolume: PhoneSystemVolume {
    private(set) var volume: Double
    var onChange: ((Double) -> Void)?
    init(_ volume: Double = 0.5) { self.volume = volume }
    func set(_ volume: Double) {
        guard volume != self.volume else { return }
        self.volume = volume
        onChange?(volume)
    }
    func refresh() {}
    func setInUse(_ inUse: Bool) {}
}
