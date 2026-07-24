#if canImport(UIKit)
import SwiftUI
import UIKit
import RespondoCore

/// Кэш загруженных изображений (без сторонних библиотек — URLSession + NSCache).
/// Ограничен по суммарной «стоимости» (cost = байты декодированных данных), чтобы
/// кэш аватаров/миниатюр не рос неограниченно.
final class RespondoImageCache: @unchecked Sendable {
    static let shared = RespondoImageCache()
    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = ImageDownloadPolicy.cacheCostLimit
        return cache
    }()

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func store(_ image: UIImage, for url: URL, cost: Int) {
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

/// Асинхронная загрузка изображения по URL с кэшированием.
@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var task: Task<Void, Never>?

    func load(_ url: URL?) {
        guard let url else { image = nil; return }
        if let cached = RespondoImageCache.shared.image(for: url) {
            image = cached
            return
        }
        task?.cancel()
        task = Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }
                // Потолок размера: не декодируем негодные/слишком большие ответы (защита памяти).
                guard ImageDownloadPolicy.isAcceptable(byteCount: data.count) else {
                    RespondoLog.debug("image rejected: \(data.count) bytes (limit \(ImageDownloadPolicy.maxBytes))")
                    return
                }
                guard let loaded = UIImage(data: data) else { return }
                RespondoImageCache.shared.store(loaded, for: url, cost: data.count)
                if !Task.isCancelled { self.image = loaded }
            } catch {
                // Тихо игнорируем — фолбэк на инициалы/плейсхолдер в UI.
            }
        }
    }
}

/// Вью удалённого изображения с фолбэком на инициалы.
struct RemoteImageView: View {
    let url: URL?
    var fallbackInitials: String = ""
    var size: CGFloat = 28
    var tint: Color = RespondoPalette.subtleInk
    @StateObject private var loader = ImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    tint.opacity(0.15)
                    Text(fallbackInitials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundColor(tint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear { loader.load(url) }
    }
}
#endif
