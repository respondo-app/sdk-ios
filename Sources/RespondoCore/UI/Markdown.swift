import Foundation

/// Мини-парсер markdown для чат-сообщений (паритет с Flutter `mini_markdown.dart`):
/// **bold**/__bold__, *italic*/_italic_, `inline code`, [text](url), маркированные
/// (`-`/`*`) и нумерованные (`1.`) списки, заголовки (`#`…`######`) — как параграфы.
/// Реализация нативная (Foundation), платформонезависимая и чистая: разбор отделён
/// от рендера. Сканирование по `Character` (не по UTF-16) — маркеры ASCII, а составные
/// кластеры/суррогаты не разрываются.

/// Тип блока.
enum MarkdownBlockKind: Equatable {
    case paragraph
    case bullet
    case ordered
}

/// Инлайн-фрагмент с флагами оформления.
struct MarkdownInline: Equatable {
    var text: String
    var bold: Bool = false
    var italic: Bool = false
    var code: Bool = false
    /// Непустой URL, если фрагмент — ссылка (схема НЕ отфильтрована на этом слое).
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
    static func isSafeLink(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// Разбирает markdown-текст в список блоков.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        var orderedCounter = 0

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingTrailingWhitespace()
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                orderedCounter = 0
                continue
            }

            // Заголовок `#`…`######` — рендерим как параграф (без решёток).
            if let heading = headingContent(line) {
                orderedCounter = 0
                blocks.append(MarkdownBlock(kind: .paragraph, inlines: parseInline(heading)))
                continue
            }

            // Маркированный список `- ` / `* `.
            if let bullet = bulletContent(line) {
                orderedCounter = 0
                blocks.append(MarkdownBlock(kind: .bullet, inlines: parseInline(bullet)))
                continue
            }

            // Нумерованный список `1. `.
            if let ordered = orderedContent(line) {
                orderedCounter += 1
                blocks.append(MarkdownBlock(kind: .ordered, inlines: parseInline(ordered), ordinal: orderedCounter))
                continue
            }

            orderedCounter = 0
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

            // Ссылка [text](url)
            if c == "[", let match = matchLink(chars, from: i) {
                flush()
                out.append(MarkdownInline(
                    text: match.label.isEmpty ? match.url : match.label,
                    bold: bold, italic: italic, link: match.url
                ))
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
            case .paragraph:
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

    /// Содержимое элемента нумерованного списка (`\d+.` + пробел), иначе nil.
    private static func orderedContent(_ line: String) -> String? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        var digits = 0
        while i < chars.count, chars[i].isNumber { i += 1; digits += 1 }
        guard digits > 0, i < chars.count, chars[i] == "." else { return nil }
        i += 1
        guard i < chars.count, chars[i] == " " else { return nil }
        while i < chars.count, chars[i] == " " { i += 1 }
        return String(chars[i...])
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

    /// Разбирает `[label](url)` начиная с `[`. Возвращает подпись, URL и число
    /// поглощённых символов. `label` — любые символы кроме `]`; `url` — непустая
    /// последовательность кроме `)` (обрезается по краям).
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
        while i < n, chars[i] != ")" {
            url.append(chars[i])
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
