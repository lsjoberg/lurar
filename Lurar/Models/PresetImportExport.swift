import AppKit
import Foundation
import UniformTypeIdentifiers
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "PresetIO")

/// Save/Open-panel-driven export and import for user presets.
///
/// On-disk format:
///   - `.lurarpreset`  — one preset, encoded as a single JSON object
///   - `.lurarpresets` — multiple presets, encoded as a JSON array (same
///     shape as `presets.json`). A real ZIP would have been spec-faithful,
///     but the JSON-array form round-trips through the same encoder, has no
///     external-tool dependency, and the files stay small anyway.
enum PresetImportExport {
    static let singleExt = "lurarpreset"
    static let bundleExt = "lurarpresets"

    struct ImportSummary {
        var imported: Int
        var renamed: Int
        var message: String {
            switch (imported, renamed) {
            case (0, _): return "Nothing imported"
            case (1, 0): return "Imported 1 preset"
            case (let n, 0): return "Imported \(n) presets"
            case (1, 1): return "Imported 1 preset, renamed 1 due to conflict"
            case (let n, 1): return "Imported \(n) presets, renamed 1 due to conflict"
            case (let n, let r): return "Imported \(n) presets, renamed \(r) due to conflicts"
            }
        }
    }

    // MARK: - Export

    @MainActor
    static func exportSingle(_ preset: EQPreset) {
        let panel = NSSavePanel()
        panel.title = "Export Preset"
        panel.allowedContentTypes = [singleType]
        panel.nameFieldStringValue = "\(sanitize(preset.name)).\(singleExt)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try makeEncoder().encode(preset)
            try data.write(to: url, options: .atomic)
        } catch {
            presentError("Couldn't export preset", error: error)
        }
    }

    @MainActor
    static func exportLibrary(_ presets: [EQPreset]) {
        // Flat is bundled with the app; no point shipping it in the user's
        // export. AutoEq-catalog presets aren't in `presets` to begin with.
        let exportable = presets.filter { $0.id != EQPreset.flatID }
        guard !exportable.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to export"
            alert.informativeText = "Save a custom preset first."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Preset Library"
        panel.allowedContentTypes = [bundleType]
        panel.nameFieldStringValue = "Lurar Presets.\(bundleExt)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try makeEncoder().encode(exportable)
            try data.write(to: url, options: .atomic)
        } catch {
            presentError("Couldn't export library", error: error)
        }
    }

    // MARK: - Import

    @MainActor
    static func importIntoStore(_ store: PresetStore) -> ImportSummary? {
        let panel = NSOpenPanel()
        panel.title = "Import Presets"
        panel.allowedContentTypes = [singleType, bundleType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let incoming = try decodePresets(at: url)
            let result = store.merge(incoming: incoming)
            return ImportSummary(imported: result.imported, renamed: result.renamed)
        } catch {
            presentError("Couldn't import presets", error: error)
            return nil
        }
    }

    private static func decodePresets(at url: URL) throws -> [EQPreset] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let ext = url.pathExtension.lowercased()
        if ext == singleExt {
            return [try decoder.decode(EQPreset.self, from: data)]
        }
        if ext == bundleExt {
            return try decoder.decode([EQPreset].self, from: data)
        }
        // Unknown extension — try array first, then single.
        if let array = try? decoder.decode([EQPreset].self, from: data) { return array }
        return [try decoder.decode(EQPreset.self, from: data)]
    }

    // MARK: - Helpers

    private static var singleType: UTType {
        UTType(filenameExtension: singleExt) ?? .json
    }

    private static var bundleType: UTType {
        UTType(filenameExtension: bundleExt) ?? .json
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    @MainActor
    private static func presentError(_ message: String, error: Error) {
        log.error("\(message): \(String(describing: error))")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = (error as NSError).localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Preset" }
        return trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
