#if canImport(UIKit)
import UIKit
import Combine
import RespondoCore

/// Наблюдатель жизненного цикла приложения. Подписывается на системные уведомления
/// фон/форграунд (через Combine-паблишер `NotificationCenter`) и прокидывает их в
/// платформонезависимые хуки движка (core сам UIKit не знает). Ставится один раз при
/// `Respondo.initialize`.
@MainActor
final class RespondoLifecycleMonitor {
    static let shared = RespondoLifecycleMonitor()

    private var installed = false
    private var cancellables: Set<AnyCancellable> = []

    /// Идемпотентно подписывается на фон/форграунд и форвардит в движок.
    func installIfNeeded() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        // Lifecycle-уведомления UIApplication постятся на главном потоке.
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in MainActor.assumeIsolated { RespondoEngine.shared.applicationDidEnterBackground() } }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { _ in MainActor.assumeIsolated { RespondoEngine.shared.applicationWillEnterForeground() } }
            .store(in: &cancellables)
    }
}
#endif
