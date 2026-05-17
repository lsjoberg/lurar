import Combine
import Sparkle

@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool = false

    let controller: SPUStandardUpdaterController

    private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
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
