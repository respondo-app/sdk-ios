import Foundation

/// Политика загрузки удалённых изображений (аватары/миниатюры вложений).
/// Платформонезависимая — используется UI-слоем (`ImageLoader`) и покрыта тестами.
public enum ImageDownloadPolicy {
    /// Потолок размера ответа для декодирования: 10 МБ. Вложения загружаются до 20 МБ
    /// (`ConversationController.attach`), но для показа в треде/аватаров декодируем не
    /// более половины лимита — миниатюры столько не весят, а память ограничиваем.
    public static let maxBytes = 10 * 1024 * 1024

    /// Верхняя граница «стоимости» кэша изображений (cost = байты декодированных данных).
    public static let cacheCostLimit = 64 * 1024 * 1024

    /// Годен ли ответ к декодированию: непустой и не превышает потолок.
    public static func isAcceptable(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maxBytes
    }
}
