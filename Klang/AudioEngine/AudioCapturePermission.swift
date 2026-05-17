import Foundation
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "AudioCapturePermission")

/// Wraps the private TCC SPI required to request the system-audio-capture
/// permission used by Core Audio Process Taps on macOS 14.2+. No public API
/// triggers the prompt for `kTCCServiceAudioCapture`, so we have to call into
/// `/System/Library/PrivateFrameworks/TCC.framework` directly. Pattern lifted
/// from Apple-employee sample app `AudioCap`.
enum AudioCapturePermission {
    enum Status {
        case authorized
        case denied
        case unknown
    }

    /// Returns the current permission status without prompting the user.
    static func preflight() -> Status {
        guard let fn = preflightSPI else {
            log.warning("TCCAccessPreflight SPI not available")
            return .unknown
        }
        let result = fn("kTCCServiceAudioCapture" as CFString, nil)
        // TCCAccessPreflight: 0 = authorized, 1 = denied/needs-prompt, 2 = denied.
        // We log the raw code because the codes are private SPI and have
        // shifted across macOS releases — when users report "I granted it
        // but Klang still says blocked" the OSLog tells us whether preflight
        // is genuinely returning the denied code or something the switch
        // here is misclassifying.
        log.debug("TCCAccessPreflight(kTCCServiceAudioCapture) = \(result, privacy: .public)")
        switch result {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Triggers the system permission prompt for `kTCCServiceAudioCapture` if the
    /// user has not yet granted/denied it. Calls `completion` on whichever queue
    /// TCC delivers the result on (typically a background thread). The caller is
    /// responsible for any required thread hop. (Bouncing back to main here would
    /// deadlock `ensureAuthorized` since that helper blocks the calling thread.)
    static func request(completion: @escaping (Bool) -> Void) {
        guard let fn = requestSPI else {
            log.fault("TCCAccessRequest SPI not available")
            completion(false)
            return
        }
        fn("kTCCServiceAudioCapture" as CFString, nil) { granted in
            log.notice("TCC audio-capture request finished: granted=\(granted, privacy: .public)")
            completion(granted)
        }
    }

    /// Synchronous helper for engine startup. Returns true if we are (or become)
    /// authorized. Blocks the calling thread on the prompt — only call from a
    /// background queue if blocking the main thread would freeze the UI.
    static func ensureAuthorized() -> Bool {
        switch preflight() {
        case .authorized:
            return true
        case .denied, .unknown:
            let sem = DispatchSemaphore(value: 0)
            var result = false
            request { granted in
                result = granted
                sem.signal()
            }
            sem.wait()
            return result
        }
    }

    // MARK: - Private TCC SPI

    private typealias PreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFuncType = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
        return dlopen(path, RTLD_NOW)
    }()

    private static let preflightSPI: PreflightFuncType? = {
        guard let apiHandle else { return nil }
        guard let sym = dlsym(apiHandle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFuncType.self)
    }()

    private static let requestSPI: RequestFuncType? = {
        guard let apiHandle else { return nil }
        guard let sym = dlsym(apiHandle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFuncType.self)
    }()
}
