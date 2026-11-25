import Foundation

/// Мини-парсер markdown для чат-сообщений (паритет с Flutter `mini_markdown.dart`):
/// **bold**/__bold__, *italic*/_italic_, `inline code`, [text](url), картинки ![alt](url) —
/// ссылкой с подписью alt (или адресом), http(s)-URL, маркированные
/// (`-`/`*`) и нумерованные (`1.`) списки, заголовки (`#`…`######`) — жирной строкой, цитаты
/// (`> `) — строкой без маркера, пустая строка между блоками — отступ абзаца (`.gap`).
/// Реализация нативная (Foundation), платформонезависимая и чистая: разбор отделён
/// от рендера. Сканирование по `Character` (не по UTF-16) — маркеры ASCII, а составные
/// кластеры/суррогаты не разрываются.

/// Тип блока.
enum MarkdownBlockKind: Equatable {
    case paragraph
    case bullet
    case ordered
    /// Пустая строка между абзацами: без неё абзац, отделённый пустой строкой, рисовался
    /// вплотную, как простой перенос (тело макроса, 2026-10-30).
    case gap
}

/// Инлайн-фрагмент с флагами оформления.
struct MarkdownInline: Equatable {
    var text: String
    var bold: Bool = false
    var italic: Bool = false
    var code: Bool = false
    /// Непустой URL, если фрагмент — безопасная ссылка; небезопасные схемы остаются текстом.
    var link: String?
}

/// Блок: абзац или элемент списка с инлайнами.
struct MarkdownBlock: Equatable {
    var kind: MarkdownBlockKind
    var inlines: [MarkdownInline]
    /// Порядковый номер для нумерованного списка.
    var ordinal: Int?
}

public enum Markdown {
    /// Разрешённые к клику схемы ссылок — только http/https (паритет с Flutter
    /// `markdown_view.dart`: прочие схемы, включая `javascript:`, кликом игнорируются).
    public static func isSafeLink(_ url: String) -> Bool {
        guard !url.contains(where: { $0.isWhitespace || $0 == "\\" }),
              !url.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return false }
        return components.url != nil
    }

    /// Разбирает markdown-текст в список блоков.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        // Номер пункта: первый пункт серии берёт номер из источника, следующие — +1. Пустая
        // строка серию НЕ рвёт: импорт пишет список «рыхлым» («1. a\n\n2. b\n\n3. c»), и
        // счётчик, сбрасываемый на пустой строке, нумеровал каждый пункт «1.». Рвёт серию
        // любой другой блок.
        var lastOrdinal: Int?
        // Пустая строка после блока — отступ абзаца перед СЛЕДУЮЩИМ блоком: один на серию
        // пустых строк, и ни одного в начале или в конце сообщения.
        var pendingGap = false

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingTrailingWhitespace()
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !blocks.isEmpty { pendingGap = true }
                continue
            }
            if pendingGap {
                blocks.append(MarkdownBlock(kind: .gap, inlines: []))
                pendingGap = false
            }

            // `\#` в начале строки — литерал `#`, не заголовок: канонический вид тела хранит этот
            // экран, чтобы «\# of orders» не стал заголовком (паритет с Android и Flutter).
            if let literal = escapedHeadingText(line) {
                lastOrdinal = nil
                blocks.append(MarkdownBlock(kind: .paragraph, inlines: parseInline(literal)))
                continue
            }

            // Заголовок `#`…`######` — жирной строкой, без решёток (как Telegram, WhatsApp, почта).
            if let heading = headingContent(line) {
                lastOrdinal = nil
                let inlines = parseInline(heading.replacingOccurrences(of: "**", with: "")).map { inline -> MarkdownInline in
                    var bold = inline
                    bold.bold = true
                    return bold
                }
                blocks.append(MarkdownBlock(kind: .paragraph, inlines: inlines))
                continue
            }

            // Цитата `> ` — строкой без маркера.
            if let quote = quoteContent(line) {
                lastOrdinal = nil
                blocks.append(MarkdownBlock(kind: .paragraph, inlines: parseInline(quote)))
                continue
            }

            // Маркированный список `- ` / `* `.
            if let bullet = bulletContent(line) {
                lastOrdinal = nil
                blocks.append(MarkdownBlock(kind: .bullet, inlines: parseInline(bullet)))
                continue
            }

            // Нумерованный список `1. `.
            if let ordered = orderedContent(line) {
                let ordinal = lastOrdinal.map { $0 + 1 } ?? ordered.number
                lastOrdinal = ordinal
                blocks.append(MarkdownBlock(kind: .ordered, inlines: parseInline(ordered.text), ordinal: ordinal))
                continue
            }

            lastOrdinal = nil
            blocks.append(MarkdownBlock(kind: .paragraph, inlines: parseInline(line)))
        }

        if blocks.isEmpty {
            blocks.append(MarkdownBlock(kind: .paragraph, inlines: [MarkdownInline(text: "")]))
        }
        return blocks
    }

    /// Разбирает одну строку в инлайн-фрагменты. Скан слева направо; при неполном
    /// маркере символы выводятся как обычный текст (паритет с Flutter).
    static func parseInline(_ text: String) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var buffer = ""
        var bold = false
        var italic = false
        let chars = Array(text)
        let n = chars.count

        func flush() {
            if !buffer.isEmpty {
                out.append(MarkdownInline(text: buffer, bold: bold, italic: italic))
                buffer = ""
            }
        }

        var i = 0
        while i < n {
            let c = chars[i]

            // Инлайн-код `...`
            if c == "`", let end = firstIndex(of: "`", in: chars, from: i + 1) {
                flush()
                out.append(MarkdownInline(text: String(chars[(i + 1)..<end]), code: true))
                i = end + 1
                continue
            }

            // Картинка ![alt](url) — ссылкой с подписью alt (пустой alt — адресом), без «!»:
            // картинки в пузыре SDK не рисует, а «!» перед ссылкой клиент читал буквально
            // (тела макросов несут картинки).
            if c == "!", i + 1 < n, chars[i + 1] == "[", let match = matchLink(chars, from: i + 1) {
                flush()
                let label = match.label.trimmingCharacters(in: .whitespaces)
                out.append(MarkdownInline(
                    text: label.isEmpty ? match.url : label,
                    bold: bold, italic: italic, link: isSafeLink(match.url) ? match.url : nil
                ))
                i += 1 + match.consumed
                continue
            }

            // Ссылка [text](url)
            if c == "[", let match = matchLink(chars, from: i) {
                flush()
                out.append(MarkdownInline(
                    text: match.label.isEmpty ? match.url : match.label,
                    bold: bold, italic: italic, link: isSafeLink(match.url) ? match.url : nil
                ))
                i += match.consumed
                continue
            }

            // Голый URL поглощается целиком до разбора emphasis: `_` в пути или
            // query не превращается в маркер курсива. Код и markdown-ссылки уже
            // обработаны выше и повторно не линкуются.
            if let match = matchBareLink(chars, from: i) {
                flush()
                out.append(MarkdownInline(text: match.url, bold: bold, italic: italic, link: match.url))
                i += match.consumed
                continue
            }

            // Жирный **...** / __...__
            if (c == "*" && peek(chars, i, "*", "*")) || (c == "_" && peek(chars, i, "_", "_")) {
                flush()
                bold.toggle()
                i += 2
                continue
            }

            // Курсив *...* / _..._
            if c == "*" || c == "_" {
                flush()
                italic.toggle()
                i += 1
                continue
            }

            buffer.append(c)
            i += 1
        }
        flush()

        if out.isEmpty { out.append(MarkdownInline(text: "")) }
        return out
    }

    /// Собирает Foundation `AttributedString`: bold/italic/code через
    /// `inlinePresentationIntent`, http/https-ссылки через `.link` (прочие схемы —
    /// как обычный текст). Блоки разделяются переводом строки, элементы списков —
    /// маркерами `•` / `N.`.
    public static func attributedString(from source: String) -> AttributedString {
        var result = AttributedString()
        for (index, block) in parse(source).enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            switch block.kind {
            case .paragraph, .gap:
                // .gap: перевод строки выше без текста — пустая строка, отступ абзаца.
                break
            case .bullet:
                result.append(AttributedString("•  "))
            case .ordered:
                result.append(AttributedString("\(block.ordinal ?? 1).  "))
            }
            for inline in block.inlines {
                var run = AttributedString(inline.text)
                var intent: InlinePresentationIntent = []
                if inline.bold { intent.insert(.stronglyEmphasized) }
                if inline.italic { intent.insert(.emphasized) }
                if inline.code { intent.insert(.code) }
                if !intent.isEmpty { run.inlinePresentationIntent = intent }
                if let link = inline.link, isSafeLink(link), let url = URL(string: link) {
                    run.link = url
                }
                result.append(run)
            }
        }
        return result
    }

    // MARK: - Разбор блоков

    /// Строка `\#…` (до трёх ведущих пробелов) — её текст без бэкслэша, иначе nil.
    private static func escapedHeadingText(_ line: String) -> String? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, i < 3, chars[i] == " " { i += 1 }
        guard i + 1 < chars.count, chars[i] == "\\", chars[i + 1] == "#" else { return nil }
        return String(chars[(i + 1)...])
    }

    /// Содержимое строки-заголовка `#`…`######` после решёток и пробела, иначе nil.
    private static func headingContent(_ line: String) -> String? {
        let chars = Array(line)
        var i = 0
        // Допускаем до трёх ведущих пробелов (как CommonMark).
        var leading = 0
        while i < chars.count, chars[i] == " ", leading < 3 { i += 1; leading += 1 }
        var hashes = 0
        while i < chars.count, chars[i] == "#", hashes < 6 { i += 1; hashes += 1 }
        guard hashes > 0, i < chars.count, chars[i] == " " else { return nil }
        while i < chars.count, chars[i] == " " { i += 1 }
        return String(chars[i...])
    }

    /// Содержимое строки цитаты (`>` + необязательный пробел, до трёх ведущих пробелов), иначе nil.
    private static func quoteContent(_ line: String) -> String? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, i < 3, chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == ">" else { return nil }
        i += 1
        if i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        return String(chars[i...])
    }

    /// Содержимое элемента маркированного списка (`-`/`*` + пробел), иначе nil.
    private static func bulletContent(_ line: String) -> String? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == "-" || chars[i] == "*" else { return nil }
        i += 1
        guard i < chars.count, chars[i] == " " else { return nil }
        while i < chars.count, chars[i] == " " { i += 1 }
        return String(chars[i...])
    }

    /// Номер и содержимое элемента нумерованного списка (`\d+.` + пробел), иначе nil.
    private static func orderedContent(_ line: String) -> (number: Int, text: String)? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        let digitsStart = i
        while i < chars.count, chars[i].isNumber { i += 1 }
        guard i > digitsStart, i < chars.count, chars[i] == "." else { return nil }
        let number = Int(String(chars[digitsStart..<i])) ?? 1
        i += 1
        guard i < chars.count, chars[i] == " " else { return nil }
        while i < chars.count, chars[i] == " " { i += 1 }
        return (number, String(chars[i...]))
    }

    // MARK: - Разбор инлайнов

    private static func firstIndex(of target: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    private static func peek(_ chars: [Character], _ i: Int, _ a: Character, _ b: Character) -> Bool {
        i + 1 < chars.count && chars[i] == a && chars[i + 1] == b
    }

    /// Автоссылки начинаются только на границе токена. Конечная пунктуация и
    /// внешние скобки остаются текстом, сбалансированные скобки внутри URL — URL.
    private static func matchBareLink(_ chars: [Character], from start: Int) -> (url: String, consumed: Int)? {
        guard chars[start] == "h" || chars[start] == "H" else { return nil }
        if start > 0 {
            let previous = chars[start - 1]
            if previous.isLetter || previous.isNumber || "_/@.+-:$%\\\"'".contains(previous) { return nil }
        }
        let prefix = String(chars[start..<min(start + 8, chars.count)]).lowercased()
        guard prefix.hasPrefix("https://") || prefix.hasPrefix("http://") else { return nil }

        var end = start
        var brackets: [Character] = []
        let closingToOpening: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        scan: while end < chars.count {
            let c = chars[end]
            if c.isWhitespace || "<>\"'`*".contains(c) { break }
            if c == "(" || c == "[" || c == "{" {
                brackets.append(c)
            } else if let expected = closingToOpening[c] {
                guard brackets.last == expected else { break scan }
                brackets.removeLast()
            }
            end += 1
        }
        while end > start {
            let last = chars[end - 1]
            if ".,!?;:…".contains(last) {
                end -= 1
            } else {
                break
            }
        }
        let url = String(chars[start..<end])
        guard isSafeLink(url) else { return nil }
        return (url, end - start)
    }

    /// Разбирает `[label](url)` начиная с `[`. Сбалансированные круглые скобки
    /// внутри URL входят в ссылку; первая несбалансированная закрывает её.
    private static func matchLink(_ chars: [Character], from start: Int) -> (label: String, url: String, consumed: Int)? {
        let n = chars.count
        var i = start + 1
        var label = ""
        while i < n, chars[i] != "]" {
            label.append(chars[i])
            i += 1
        }
        guard i < n, chars[i] == "]" else { return nil }
        i += 1
        guard i < n, chars[i] == "(" else { return nil }
        i += 1
        let urlStart = i
        var url = ""
        var depth = 0
        while i < n {
            let c = chars[i]
            if c == ")" {
                if depth == 0 { break }
                depth -= 1
            } else if c == "(" {
                depth += 1
            }
            url.append(c)
            i += 1
        }
        guard i < n, chars[i] == ")", i > urlStart else { return nil }
        i += 1
        return (label, url.trimmingCharacters(in: .whitespaces), i - start)
    }
}

private extension String {
    /// Обрезает завершающие пробельные символы (аналог Dart `trimRight`).
    func replacingTrailingWhitespace() -> String {
        var view = self[...]
        while let last = view.last, last.isWhitespace {
            view = view[..<view.index(before: view.endIndex)]
        }
        return String(view)
    }
}
