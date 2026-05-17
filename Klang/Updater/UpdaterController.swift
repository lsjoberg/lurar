import Combine
import OSLog
import Sparkle

private let updaterLog = Logger(subsystem: "se.linus.klang", category: "Updater")

@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool = false

    let controller: SPUStandardUpdaterController

    private var cancellable: AnyCancellable?

    init() {
        // Sparkle refuses to start without a valid SUPublicEDKey and the
        // standard user driver surfaces "Unable to Check For Updates" at
        // launch when startup fails. Unsigned dev builds ship with an empty
        // key (project.yml defaults SPARKLE_PUBLIC_ED_KEY to ""), so skip
        // auto-start in that case. The "Check for Updates…" button in
        // Settings is already gated on `canCheckForUpdates`, which stays
        // false until the updater is started.
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let shouldStart = !publicKey.isEmpty
        if !shouldStart {
            updaterLog.info("SUPublicEDKey is empty; skipping Sparkle auto-start.")
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: shouldStart,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
