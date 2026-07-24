import Foundation

/// Версия SDK. Совпадает с суффиксом User-Agent (`RespondoSDK/<version>`)
/// и полем `sdk_version` в автоконтексте metadata.
public enum SdkVersion {
    public static let current = "0.1.0"
    /// Значение поля `source` в запросах — отличает мобильный трафик iOS в инбоксе/аналитике.
    public static let source = "sdk-ios"
    /// Значение поля `platform` в автоконтексте.
    public static let platform = "ios"
    public static var userAgent: String { "RespondoSDK/\(current)" }
}
