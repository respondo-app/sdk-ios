#if canImport(UIKit)
import UIKit
import SwiftUI
import RespondoCore

/// UIKit-обёртка чата для встраивания хостом вручную (без фасадного sheet).
/// Хостит SwiftUI `ChatView` текущей беседы.
public final class RespondoChatViewController: UIViewController {
    private let controller: ConversationController
    private let engagement: EngagementController

    private init(controller: ConversationController, engagement: EngagementController) {
        self.controller = controller
        self.engagement = engagement
        super.init(nibName: nil, bundle: nil)
    }

    /// Создаёт контроллер чата, если SDK инициализирован (иначе nil).
    public static func make() -> RespondoChatViewController? {
        guard let controller = RespondoEngine.shared.controller,
              let engagement = RespondoEngine.shared.engagement else { return nil }
        return RespondoChatViewController(controller: controller, engagement: engagement)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let root = ChatContainerView(controller: controller, engagement: engagement, surface: .thread) { [weak self] in
            self?.dismiss(animated: true)
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}

/// Реализация `ChatPresenter` через системный bottom-sheet с детентами по chat_size.
@MainActor
final class RespondoPresenter: ChatPresenter {
    private weak var presentedController: UIViewController?

    var isPresented: Bool { presentedController != nil && presentedController?.presentingViewController != nil }

    func present(surface: ChatSurface) {
        guard let controller = RespondoEngine.shared.controller,
              let engagement = RespondoEngine.shared.engagement else {
            RespondoLog.warn("presenter: контроллер беседы ещё не готов")
            return
        }
        if let existing = presentedController, existing.presentingViewController != nil {
            return // уже показан
        }
        let theme = controller.theme
        let root = ChatContainerView(controller: controller, engagement: engagement, surface: surface) {
            Respondo.close()
        }
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .white
        configureSheet(host, theme: theme)
        topViewController()?.present(host, animated: true)
        presentedController = host
    }

    func dismiss() {
        presentedController?.dismiss(animated: true)
        presentedController = nil
    }

    private func configureSheet(_ host: UIViewController, theme: ResolvedTheme) {
        guard let sheet = host.sheetPresentationController else { return }
        if #available(iOS 16.0, *) {
            let initial = UISheetPresentationController.Detent.custom(identifier: .init("respondo.initial")) { context in
                context.maximumDetentValue * theme.initialDetentFraction
            }
            let expanded = UISheetPresentationController.Detent.custom(identifier: .init("respondo.max")) { context in
                context.maximumDetentValue * theme.maxDetentFraction
            }
            sheet.detents = [initial, expanded]
        } else {
            sheet.detents = [.medium(), .large()]
        }
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = theme.cornerRadius
    }

    /// Находит верхний презентующий контроллер активной сцены.
    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
            ?? scenes.flatMap { $0.windows }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Однократная установка презентера в движок.
enum RespondoPresenterInstaller {
    @MainActor private static var installed = false

    @MainActor
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        RespondoEngine.shared.setPresenter(RespondoPresenter())
    }
}
#endif
