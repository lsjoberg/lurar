import AppKit
import Carbon.HIToolbox
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "BypassHotkey")

/// Global hold-to-bypass hotkey. Pressing the chord swaps the engine to the
/// bundled Flat preset via `EQEngine.setBypassed(true)`; releasing restores
/// the user's current preset. Default chord is ⌥B.
///
/// Carbon's `RegisterEventHotKey` works in an unsandboxed app (Klang's
/// entitlements opt out of the sandbox) without needing the input-monitoring
/// TCC service. We install handlers for both `kEventHotKeyPressed` and
/// `kEventHotKeyReleased` so we get the down/up edges needed for momentary
/// behaviour, and key-repeat is debounced by `setBypassed`'s own state-equal
/// early-return.
@MainActor
final class BypassHotkey {
    private static let signature: OSType = 0x4B4C4E47   // 'KLNG'
    private static let id: UInt32 = 1

    static let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_B)
    static let defaultModifiers: UInt32 = UInt32(optionKey)

    private weak var engine: EQEngine?
    private var hotKeyRef: EventHotKeyRef?
    private var pressedHandler: EventHandlerRef?
    private var releasedHandler: EventHandlerRef?

    init(engine: EQEngine) {
        self.engine = engine
        install(keyCode: Self.defaultKeyCode, modifiers: Self.defaultModifiers)
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let h = pressedHandler { RemoveEventHandler(h) }
        if let h = releasedHandler { RemoveEventHandler(h) }
    }

    private func install(keyCode: UInt32, modifiers: UInt32) {
        let userData = Unmanaged.passUnretained(self).toOpaque()

        var pressedSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pressedStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                BypassHotkey.dispatch(eventRef: eventRef, userData: userData, pressed: true)
                return noErr
            },
            1, &pressedSpec, userData, &pressedHandler
        )

        var releasedSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased)
        )
        let releasedStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                BypassHotkey.dispatch(eventRef: eventRef, userData: userData, pressed: false)
                return noErr
            },
            1, &releasedSpec, userData, &releasedHandler
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.id)
        let regStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )

        if pressedStatus != noErr || releasedStatus != noErr || regStatus != noErr {
            // -9878 = eventHotKeyExistsErr (another process owns this chord).
            log.error("Bypass hotkey install failed: pressed=\(pressedStatus, privacy: .public) released=\(releasedStatus, privacy: .public) register=\(regStatus, privacy: .public)")
        } else {
            log.notice("Bypass hotkey registered (⌥B)")
        }
    }

    /// C-callback-safe dispatch: parse the hotkey ID out of the event, verify
    /// it's ours, then hop to the main thread to call the engine. Carbon hot-
    /// key events fire on the main thread in practice, but the hop also
    /// satisfies actor isolation for the `EQEngine` call.
    private static func dispatch(eventRef: EventRef?, userData: UnsafeMutableRawPointer?, pressed: Bool) {
        guard let eventRef, let userData else { return }
        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard status == noErr,
              receivedID.signature == BypassHotkey.signature,
              receivedID.id == BypassHotkey.id
        else { return }
        let pointer = UnsafeMutableRawPointer(userData)
        DispatchQueue.main.async {
            let me = Unmanaged<BypassHotkey>.fromOpaque(pointer).takeUnretainedValue()
            me.engine?.setBypassed(pressed)
        }
    }
}
