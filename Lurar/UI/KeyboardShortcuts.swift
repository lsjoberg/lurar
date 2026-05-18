import SwiftUI

/// Single source of truth for every user-facing keyboard shortcut. The
/// cheat-sheet view (`ShortcutsView`) renders straight off this registry,
/// so adding a binding here is the only place it needs to be declared —
/// the helper `.lurarShortcut(...)` modifier wires both the
/// `.keyboardShortcut(...)` and a `"Label (\u{2318}X)"` tooltip in one go.
struct LurarShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let label: String
    let group: Group
    /// Explicit glyph override for keys whose `KeyEquivalent.character` either
    /// doesn't render (some special keys map to unprintable control codes that
    /// vary between SDK versions \u{2014} e.g. `.delete` on macOS) or where we
    /// want a friendlier display.
    let displayKey: String?

    init(
        key: KeyEquivalent,
        modifiers: EventModifiers,
        label: String,
        group: Group,
        displayKey: String? = nil
    ) {
        self.key = key
        self.modifiers = modifiers
        self.label = label
        self.group = group
        self.displayKey = displayKey
    }

    enum Group: String, CaseIterable {
        case menuBar = "Menu Bar Popover"
        case editor = "EQ Editor"
        case ab = "A/B Compare"
        case library = "Preset Library"
        case excluded = "Excluded Apps"
    }

    /// Glyph string for tooltips and the cheat sheet — e.g. "\u{2318}S",
    /// "\u{2318}\u{21E7}E", "\u{2318}\u{232B}".
    var glyph: String {
        var s = ""
        if modifiers.contains(.control) { s += "\u{2303}" }
        if modifiers.contains(.option)  { s += "\u{2325}" }
        if modifiers.contains(.shift)   { s += "\u{21E7}" }
        if modifiers.contains(.command) { s += "\u{2318}" }
        s += displayKey ?? Self.keyGlyph(for: key)
        return s
    }

    var tooltip: String { "\(label) (\(glyph))" }

    private static func keyGlyph(for key: KeyEquivalent) -> String {
        // KeyEquivalent.character maps the special keys to ASCII control codes
        // that vary across SDK revisions \u{2014} cover both common values for each
        // (backspace 0x08 / DEL 0x7F for delete; CR 0x0D / LF 0x0A for return).
        switch key.character {
        case "\r", "\n":            return "\u{21A9}"      // Return    \u{21A9}
        case "\u{7F}", "\u{08}":    return "\u{232B}"      // Delete    \u{232B}
        case "\u{1B}":              return "esc"           // Escape
        case "\t":                  return "\u{21E5}"      // Tab       \u{21E5}
        case " ":                   return "Space"
        case ",":                   return ","
        case ".":                   return "."
        case "/":                   return "/"
        default:
            return String(key.character).uppercased()
        }
    }
}

/// All bindings. Keep grouped by `LurarShortcut.Group`.
enum LurarShortcuts {
    // MARK: Menu bar popover
    static let openSettings   = LurarShortcut(key: ",", modifiers: .command, label: "Settings", group: .menuBar)
    static let quit           = LurarShortcut(key: "q", modifiers: .command, label: "Quit Lurar", group: .menuBar)
    static let openEditor     = LurarShortcut(key: "e", modifiers: .command, label: "Open EQ editor", group: .menuBar)
    static let openAB         = LurarShortcut(key: "b", modifiers: .command, label: "A/B compare", group: .menuBar)
    static let openLibrary    = LurarShortcut(key: "l", modifiers: .command, label: "Open preset library", group: .menuBar)
    static let newPreset      = LurarShortcut(key: "n", modifiers: .command, label: "New preset", group: .menuBar)
    static let suggest        = LurarShortcut(key: "d", modifiers: .command, label: "Suggest preset for device", group: .menuBar)
    static let toggleEngine   = LurarShortcut(key: "p", modifiers: .command, label: "Toggle engine on/off", group: .menuBar)
    static let showShortcuts  = LurarShortcut(key: "/", modifiers: .command, label: "Keyboard shortcuts", group: .menuBar)
    /// Documentation-only — wired in `AudioEngine/BypassHotkey.swift` via a
    /// Carbon hot-key, not through SwiftUI. Lives here so the cheat sheet
    /// can list it.
    static let bypassHold     = LurarShortcut(key: "b", modifiers: .option, label: "Bypass (hold, global)", group: .menuBar)

    // MARK: EQ editor
    static let save           = LurarShortcut(key: "s", modifiers: .command, label: "Save preset", group: .editor)
    static let discard        = LurarShortcut(key: "z", modifiers: .command, label: "Discard changes", group: .editor)
    static let deletePreset   = LurarShortcut(key: .delete, modifiers: .command, label: "Delete preset", group: .editor, displayKey: "\u{232B}")
    static let tweak          = LurarShortcut(key: "d", modifiers: .command, label: "Tweak (fork built-in)", group: .editor)
    static let resetParent    = LurarShortcut(key: "r", modifiers: [.command, .shift], label: "Reset to original", group: .editor)
    static let toggleSpectrum = LurarShortcut(key: "f", modifiers: .command, label: "Toggle spectrum overlay", group: .editor)
    static let exportPreset   = LurarShortcut(key: "e", modifiers: [.command, .shift], label: "Export current preset\u{2026}", group: .editor)
    static let exportLibrary  = LurarShortcut(key: "e", modifiers: [.command, .shift, .option], label: "Export whole library\u{2026}", group: .editor)
    static let importPresets  = LurarShortcut(key: "i", modifiers: [.command, .shift], label: "Import presets\u{2026}", group: .editor)
    static let editorNewPreset = LurarShortcut(key: "n", modifiers: .command, label: "New preset", group: .editor)
    static let editorLibrary  = LurarShortcut(key: "l", modifiers: .command, label: "Open preset library", group: .editor)

    // MARK: A/B compare
    static let abStart   = LurarShortcut(key: .return, modifiers: [], label: "Start / Vote / Finish (default action)", group: .ab, displayKey: "\u{21A9}")
    static let abToggle  = LurarShortcut(key: .space, modifiers: [], label: "Toggle A/B", group: .ab, displayKey: "Space")
    static let abSlotA   = LurarShortcut(key: "1", modifiers: [], label: "Pick slot A", group: .ab)
    static let abSlotB   = LurarShortcut(key: "2", modifiers: [], label: "Pick slot B", group: .ab)
    static let abVote    = LurarShortcut(key: "v", modifiers: [], label: "I prefer this one", group: .ab)
    static let abFinish  = LurarShortcut(key: "f", modifiers: [], label: "Finish blind session", group: .ab)
    static let abCancel  = LurarShortcut(key: .escape, modifiers: [], label: "Cancel / Done", group: .ab, displayKey: "esc")

    // MARK: Preset library
    static let focusSearch    = LurarShortcut(key: "f", modifiers: .command, label: "Focus search", group: .library)
    static let refreshCatalog = LurarShortcut(key: "r", modifiers: .command, label: "Refresh catalog", group: .library)
    static let libraryDone    = LurarShortcut(key: .return, modifiers: [], label: "Close (default action)", group: .library, displayKey: "\u{21A9}")

    // MARK: Excluded apps (Settings tab)
    static let focusFilter = LurarShortcut(key: "f", modifiers: .command, label: "Focus filter", group: .excluded)
    static let addExcluded = LurarShortcut(key: "n", modifiers: .command, label: "Add app to exclusion list", group: .excluded)

    /// Flat list for the cheat sheet to iterate. Order here is order in the sheet.
    static let all: [LurarShortcut] = [
        openSettings, openEditor, openAB, openLibrary, newPreset, suggest,
        toggleEngine, bypassHold, showShortcuts, quit,
        save, discard, tweak, resetParent, deletePreset, toggleSpectrum,
        exportPreset, exportLibrary, importPresets, editorNewPreset, editorLibrary,
        abStart, abToggle, abSlotA, abSlotB, abVote, abFinish, abCancel,
        focusSearch, refreshCatalog, libraryDone,
        focusFilter, addExcluded,
    ]
}

extension View {
    /// Bind the shortcut and add a "Label (\u{2318}X)" tooltip in one call.
    /// Use everywhere a Button declares its own action and the shortcut isn't
    /// already provided by a SwiftUI alias (`.defaultAction`, `.cancelAction`).
    func lurarShortcut(_ s: LurarShortcut) -> some View {
        self.keyboardShortcut(s.key, modifiers: s.modifiers).help(s.tooltip)
    }

    /// Tooltip only \u{2014} for controls whose key binding is wired via SwiftUI's
    /// `.defaultAction` / `.cancelAction` / `.space` aliases, so we don't want
    /// to double-bind. `label` overrides the registry's label when the same
    /// physical key is reused across phases (e.g. Return = Start / Vote / Finish).
    func lurarShortcutHelp(_ s: LurarShortcut, label: String? = nil) -> some View {
        self.help(label.map { "\($0) (\(s.glyph))" } ?? s.tooltip)
    }
}
