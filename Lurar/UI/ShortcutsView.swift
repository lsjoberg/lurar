import SwiftUI

/// Read-only cheat-sheet listing every binding in `LurarShortcuts.all`,
/// grouped by `LurarShortcut.Group`. Opened with \u{2318}/ from any focused
/// Lurar window or via the keyboard button in the menu bar popover footer.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private var grouped: [(LurarShortcut.Group, [LurarShortcut])] {
        var byGroup: [LurarShortcut.Group: [LurarShortcut]] = [:]
        for s in LurarShortcuts.all {
            byGroup[s.group, default: []].append(s)
        }
        return LurarShortcut.Group.allCases.compactMap { group in
            guard let items = byGroup[group], !items.isEmpty else { return nil }
            return (group, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped, id: \.0) { group, items in
                        section(title: group.rawValue, items: items)
                    }
                    footnote
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 460, idealWidth: 540, minHeight: 480, idealHeight: 820)
        .showsInDockWhileVisible()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
            Text("Bindings are scoped to the focused window unless noted as global.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func section(title: String, items: [LurarShortcut]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items.indices, id: \.self) { i in
                    row(items[i])
                }
            }
        }
    }

    private func row(_ s: LurarShortcut) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(s.glyph)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .frame(width: 70, alignment: .leading)
            Text(s.label)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tips").font(.subheadline.weight(.semibold))
            Text("\u{2022} Inside an EQ band\u{2019}s frequency field, \u{2191}/\u{2193} nudge the value and \u{21A9} / esc commit or cancel.")
            Text("\u{2022} Tab steps through focusable controls; Shift+Tab steps backwards.")
            Text("\u{2022} The \u{2325}B bypass hold works system-wide \u{2014} keep holding to bypass, release to resume.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}
