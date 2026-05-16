import AppKit
import SwiftUI

/// Catalog-enabled built-ins first, then the user's own presets.
@MainActor
func visiblePresets(catalog: PresetCatalog, store: PresetStore) -> [EQPreset] {
    catalog.enabledPresets + store.presets
}

extension EQPreset {
    /// Display label used in preset dropdowns: name plus a disambiguating
    /// source suffix for catalog entries.
    var menuLabel: String {
        let suffix = sourceSuffix
        guard !suffix.isEmpty else { return name }
        if name.lowercased().hasSuffix(suffix.lowercased()) {
            return name
        }
        return "\(name) · \(suffix)"
    }

    /// Short disambiguating tag from `source`. Klang's own user presets get
    /// no suffix; catalog entries surface their measurer/rig.
    var sourceSuffix: String {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("Klang") == .orderedSame {
            return ""
        }
        return trimmed
    }
}

/// NSPopUpButton wrapper used wherever we need a fixed-width preset/device
/// dropdown — SwiftUI's `Picker` ignores `.frame(width:)`.
struct FixedWidthPopUp: NSViewRepresentable {
    struct Item: Hashable {
        let id: String
        let title: String
    }

    /// Trailing menu entries that trigger a callback instead of changing the
    /// selection. Rendered below a separator at the bottom of the dropdown.
    final class Action: NSObject {
        let id: String
        let title: String
        init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    let width: CGFloat
    @Binding var selection: String
    let items: [Item]
    var actions: [Action] = []
    var onAction: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 24), pullsDown: false)
        button.controlSize = .regular
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self

        // Signature includes both item titles and action titles so toggling
        // actions on/off rebuilds the menu.
        let signature = items.map(\.title) + ["__sep__"] + actions.map(\.title)
        let existing = button.itemArray.map { item in
            item.isSeparatorItem ? "__sep__" : item.title
        }
        if signature != existing {
            button.removeAllItems()
            for item in items {
                button.addItem(withTitle: item.title)
                button.lastItem?.representedObject = item.id
            }
            if !actions.isEmpty {
                button.menu?.addItem(.separator())
                for action in actions {
                    let menuItem = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                    menuItem.representedObject = action
                    button.menu?.addItem(menuItem)
                }
            }
        }
        if let index = items.firstIndex(where: { $0.id == selection }) {
            if button.indexOfSelectedItem != index {
                button.selectItem(at: index)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: FixedWidthPopUp
        init(_ parent: FixedWidthPopUp) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let represented = sender.selectedItem?.representedObject else { return }
            if let action = represented as? Action {
                // Restore the visible selection so the action title doesn't
                // stick as the displayed value.
                if let index = parent.items.firstIndex(where: { $0.id == parent.selection }) {
                    sender.selectItem(at: index)
                }
                parent.onAction?(action.id)
            } else if let id = represented as? String {
                parent.selection = id
            }
        }
    }
}
