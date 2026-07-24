import Foundation

/// Состояние модалки чата.
public enum RespondoChatState: String, Sendable, Equatable {
    case closed
    case opening
    case open
    case closing
}
