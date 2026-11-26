import AppKit
import SwiftUI

/// The system search field (NSSearchField), for search that belongs to one column rather than
/// the window toolbar. `focusRequest` focuses it whenever the number changes (Command-F).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var focusRequest = 0

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(prompt)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var lastFocusRequest: Int
        init(_ parent: SearchField) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
        }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
