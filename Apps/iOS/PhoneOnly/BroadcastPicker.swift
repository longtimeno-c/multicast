import MulticastKit
import ReplayKit
import SwiftUI

/// The system's broadcast button, pointed at Multicast's extension. Starting and stopping a
/// screen broadcast is the system's to do: tapping this opens its sheet (Start Broadcast, or
/// Stop while one runs). It draws nothing itself; lay it over the app's own button so the tap
/// lands on it and the button underneath is what people see.
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = PhoneBroadcast.extensionBundleID
        // Only what the apps play is used; the microphone stays out of it.
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        clear(picker)
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        clear(picker)
    }

    /// The picker is one button with the system's record glyph; without the glyph it is an
    /// invisible target the size of whatever it is laid over.
    private func clear(_ picker: RPSystemBroadcastPickerView) {
        for case let button as UIButton in picker.subviews {
            button.setImage(nil, for: .normal)
            button.imageView?.isHidden = true
            button.backgroundColor = .clear
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            button.frame = picker.bounds
        }
    }
}
