import AppKit
import SwiftUI
import TaugeKit

/// The AppKit field owns focus and keyboard routing for its own window. An
/// overlay or a closing copy in another window must never consume these keys.
struct QuickOpenSearchField: NSViewRepresentable {
    let query: String
    let onChange: (String) -> Void
    let onKeyDown: (NSEvent) -> Bool
    var requiresActiveEditor = false
    var focusRequest = 0

    func makeNSView(context: Context) -> SearchInput {
        let field = SearchInput(frame: .zero)
        field.placeholderString = L("搜索主机、工作区或命令")
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.delegate = field
        return field
    }

    func updateNSView(_ field: SearchInput, context: Context) {
        field.onChange = onChange
        field.onKeyDown = onKeyDown
        field.requiresActiveEditor = requiresActiveEditor
        field.updateFocusRequest(focusRequest)
        let editor = field.currentEditor() as? NSTextView
        guard editor?.hasMarkedText() != true, (editor?.string ?? field.stringValue) != query else { return }
        field.stringValue = query
    }

    static func dismantleNSView(_ field: SearchInput, coordinator: Void) {
        field.stopMonitoring()
    }

    final class SearchInput: NSTextField, NSTextFieldDelegate {
        var onChange: ((String) -> Void)?
        var onKeyDown: ((NSEvent) -> Bool)?
        var requiresActiveEditor = false
        private var keyMonitor: Any?
        private var focusRequest = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard let window else { return }
            if window.attachedSheet == nil { window.makeFirstResponder(self) }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil else { return event }
                let editor = self.currentEditor() as? NSTextView
                guard editor?.hasMarkedText() != true,
                      !self.requiresActiveEditor || editor != nil else { return event }
                return self.onKeyDown?(event) == true ? nil : event
            }
        }

        func updateFocusRequest(_ value: Int) {
            guard focusRequest != value else { return }
            focusRequest = value
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusRequest == value, let window = self.window,
                      window.attachedSheet == nil else { return }
                window.makeFirstResponder(self)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            onChange?((currentEditor() as? NSTextView)?.string ?? stringValue)
        }

        func stopMonitoring() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }
}
