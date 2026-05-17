import Foundation
import CoreAudio
import AppKit
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "AudioProcessInfo")

/// Helpers for enumerating the Core Audio process-object list and translating
/// process objects to user-meaningful identifiers (bundle ID, app name, icon).
///
/// Lives separately from `ProcessTapInput` because the same enumeration drives
/// two clients: the tap target list (engine, audio thread setup) and the
/// excluded-apps UI (main thread, needs display metadata).
enum AudioProcessInfo {
    /// One Core Audio process object's user-facing identity. Multiple process
    /// objects can share a bundle ID (e.g., one per Safari WebContent process);
    /// `runningAudioApps()` deduplicates so the UI shows the app once.
    struct App: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let displayName: String
    }

    // MARK: - Bundle ID lookup

    /// Reads `kAudioProcessPropertyBundleID` from a Core Audio process object.
    /// Returns nil for processes that have no bundle (daemons, command-line
    /// helpers) — those can't be matched against the user's exclusion list and
    /// always go through the EQ.
    static func bundleID(for processObject: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, &cfRef)
        guard status == noErr, let cf = cfRef?.takeRetainedValue() else { return nil }
        let value = cf as String
        return value.isEmpty ? nil : value
    }

    /// Reads `kAudioProcessPropertyPID` from a Core Audio process object.
    /// Used to look up an `NSRunningApplication` for display name / icon.
    static func pid(for processObject: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }

    // MARK: - Process object enumeration

    /// Resolves the Core Audio process object representing the given pid.
    /// Used by `ProcessTapInput` to exclude its own process from the tap.
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var input = pid
        var output: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &input,
            &size,
            &output
        )
        if status != noErr {
            throw CoreAudioError.osStatus(status, "TranslatePIDToProcessObject(pid=\(pid))")
        }
        return output
    }

    /// Every audio-registered process the system knows about (whether currently
    /// producing audio or not).
    static func allProcessObjects() throws -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let s1 = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        if s1 != noErr {
            throw CoreAudioError.osStatus(s1, "kAudioHardwarePropertyProcessObjectList size")
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let s2 = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        if s2 != noErr {
            throw CoreAudioError.osStatus(s2, "kAudioHardwarePropertyProcessObjectList data")
        }
        return ids
    }

    // MARK: - UI-facing app list

    /// Snapshot of currently-running audio-registered apps for the exclusion
    /// window. Deduplicated by bundle ID (so Safari's many WebContent
    /// processes collapse into one row), sorted by display name.
    ///
    /// Lurar itself is filtered out — there's no value in offering to exclude
    /// the host process (and we already drop ourselves from the tap targets).
    static func runningAudioApps() -> [App] {
        let objects = (try? allProcessObjects()) ?? []
        let ownObject = try? processObject(for: getpid())
        var byBundleID: [String: App] = [:]
        for obj in objects {
            if let ownObject, obj == ownObject { continue }
            guard let bundleID = bundleID(for: obj) else { continue }
            if byBundleID[bundleID] != nil { continue }
            byBundleID[bundleID] = App(
                bundleID: bundleID,
                displayName: displayName(forBundleID: bundleID, processObject: obj)
            )
        }
        return byBundleID.values.sorted {
            $0.displayName.localizedCompare($1.displayName) == .orderedAscending
        }
    }

    /// Best-effort display name for a bundle ID. Prefer `NSRunningApplication`
    /// (matches what the user sees in the Dock); fall back to the bundle
    /// `CFBundleName` or the bundle ID itself for helper processes.
    static func displayName(forBundleID bundleID: String, processObject: AudioObjectID? = nil) -> String {
        if let pid = processObject.flatMap({ pid(for: $0) }),
           let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String),
           !name.isEmpty {
            return name
        }
        return bundleID
    }

    /// Resolves a Finder icon for a bundle ID, looking first at any currently
    /// running instance (cheaper) and falling back to LaunchServices' app URL.
    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

// MARK: - Process-list change listener

/// Fires whenever the system's audio process-object list changes (apps start
/// or stop registering with Core Audio). Used by the excluded-apps window
/// to refresh its running-apps list live.
final class AudioProcessListChangeListener {
    typealias Handler = () -> Void

    private let handler: Handler
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var block: AudioObjectPropertyListenerBlock?

    init(handler: @escaping Handler) {
        self.handler = handler
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handler()
        }
        self.block = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            log.error("Failed to register process-list change listener: \(status)")
        }
    }

    deinit {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }
}
