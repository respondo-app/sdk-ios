import Foundation

/// Команда фасада, отложенная до завершения `init` (command-queue, api-surface §7).
enum RespondoCommand {
    case identify(RespondoIdentity)
    case track(name: String, properties: [String: JSONValue])
    case open
    case close
    case openNews
    case openChecklists
    case startSurvey(String)
    case setPushToken(String)
    case clearPushToken
    case handlePush(RespondoPushPayload)
}

/// Упорядоченная (FIFO) очередь команд с ограничением размера.
/// При переполнении отбрасываются самые старые НЕ-handlePush вызовы (защита от утечки,
/// если `init` так и не вызвали). `identify` при проигрывании схлопывается до последнего.
struct CommandQueue {
    static let maxSize = 256
    private(set) var commands: [RespondoCommand] = []

    mutating func enqueue(_ command: RespondoCommand) {
        commands.append(command)
        guard commands.count > Self.maxSize else { return }
        // Отбрасываем самый старый не-handlePush вызов.
        if let index = commands.firstIndex(where: { if case .handlePush = $0 { return false } else { return true } }) {
            commands.remove(at: index)
            RespondoLog.warn("command queue overflow — самый старый вызов отброшен")
        } else {
            commands.removeFirst()
        }
    }

    /// Возвращает команды для проигрывания, схлопывая множественные identify до последнего.
    func replayOrder() -> [RespondoCommand] {
        // Индекс последнего identify — только он применяется (личность это состояние).
        var lastIdentifyIndex: Int?
        for (index, command) in commands.enumerated() {
            if case .identify = command { lastIdentifyIndex = index }
        }
        return commands.enumerated().compactMap { index, command in
            if case .identify = command, index != lastIdentifyIndex { return nil }
            return command
        }
    }

    mutating func clear() {
        commands.removeAll()
    }
}
