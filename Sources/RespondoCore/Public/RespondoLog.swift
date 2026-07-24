import Foundation
import os

/// Уровень логирования SDK. По умолчанию показываются `warn` и `error`.
public enum RespondoLogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    public static func < (lhs: RespondoLogLevel, rhs: RespondoLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Тонкая обёртка над `os.Logger` с единым префиксом `Respondo:`.
/// Принцип: SDK не роняет host-приложение — ошибки логируются, а не бросаются.
public enum RespondoLog {
    /// Минимальный уровень, который печатается. Настраивается host-приложением.
    nonisolated(unsafe) public static var minLevel: RespondoLogLevel = .warn

    private static let logger = Logger(subsystem: "ai.respondo.sdk", category: "Respondo")

    public static func debug(_ message: @autoclosure () -> String) {
        emit(.debug, message())
    }

    public static func info(_ message: @autoclosure () -> String) {
        emit(.info, message())
    }

    public static func warn(_ message: @autoclosure () -> String) {
        emit(.warn, message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        emit(.error, message())
    }

    private static func emit(_ level: RespondoLogLevel, _ message: String) {
        guard level >= minLevel else { return }
        switch level {
        case .debug: logger.debug("Respondo: \(message, privacy: .public)")
        case .info: logger.info("Respondo: \(message, privacy: .public)")
        case .warn: logger.warning("Respondo: \(message, privacy: .public)")
        case .error: logger.error("Respondo: \(message, privacy: .public)")
        }
    }
}
