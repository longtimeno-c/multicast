import AppKit
import SwiftUI

/// The system search field (NSSearchField), for search that belongs to one column rather than
/// the window toolbar. `focusRequest` focuses it whenever the number changes (Command-F).
/// Escape and the field's clear button empty it.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var focusRequest = 0

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        // The clear button sends the action, not a text change.
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
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

        @objc func changed(_ field: NSSearchField) {
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        /// Escape empties the search (and keeps the field focused for the next one).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSSearchField else { return false }
            field.stringValue = ""
            parent.text = ""
            return true
        }
    }
}
