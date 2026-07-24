import Foundation
#if canImport(UIKit)
import UIKit

/// Открытие URL во внешнем браузере, когда host не перехватил ссылку.
enum UIApplicationOpener {
    @MainActor
    static func open(_ url: URL) async {
        guard UIApplication.shared.canOpenURL(url) else { return }
        await UIApplication.shared.open(url)
    }
}
#endif
