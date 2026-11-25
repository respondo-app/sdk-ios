import XCTest
@testable import RespondoCore

/// P1-1: мини-парсер markdown и рендер в AttributedString.
/// Паритет с Flutter `mini_markdown.dart`; злые входы не роняют парсер, а
/// небезопасные схемы ссылок (`javascript:` и т. п.) не становятся кликабельными.
final class MarkdownTests: XCTestCase {
    // MARK: - Инлайны

    func testBoldItalicCode() {
        XCTAssertEqual(
            Markdown.parseInline("**bold** and *italic* and `code`"),
            [
                MarkdownInline(text: "bold", bold: true),
                MarkdownInline(text: " and "),
                MarkdownInline(text: "italic", italic: true),
                MarkdownInline(text: " and "),
                MarkdownInline(text: "code", code: true),
            ]
        )
    }

    func testLinkLabelAndUrl() {
        let inlines = Markdown.parseInline("see [docs](https://respondo.ai/docs)")
        XCTAssertEqual(inlines.last, MarkdownInline(text: "docs", link: "https://respondo.ai/docs"))
    }

    func testEmptyLabelFallsBackToUrl() {
        let inlines = Markdown.parseInline("[](https://x.io)")
        XCTAssertEqual(inlines, [MarkdownInline(text: "https://x.io", link: "https://x.io")])
    }

    func testBareHttpLinkAutolinksAndStripsTrailingPunctuation() {
        let inlines = Markdown.parseInline("open https://foo.bar/path?q=1!")
        XCTAssertEqual(inlines, [
            MarkdownInline(text: "open "),
            MarkdownInline(text: "https://foo.bar/path?q=1", link: "https://foo.bar/path?q=1"),
            MarkdownInline(text: "!"),
        ])
    }

    func testBareLinkKeepsBalancedParenthesesAndTrimsUnmatchedClosing() {
        let inlines = Markdown.parseInline("see https://example.com/a_(b))")
        XCTAssertEqual(inlines.dropFirst().first, MarkdownInline(text: "https://example.com/a_(b)", link: "https://example.com/a_(b)"))
        XCTAssertEqual(inlines.last, MarkdownInline(text: ")"))
    }

    func testBareLinkStopsAtUnmatchedClosingBeforeFollowingText() {
        let inlines = Markdown.parseInline("see https://example.com/a)tail")
        XCTAssertEqual(inlines.dropFirst().first, MarkdownInline(text: "https://example.com/a", link: "https://example.com/a"))
        XCTAssertEqual(inlines.last, MarkdownInline(text: ")tail"))
    }

    func testBareLinkPreservesUnderscoresAndIsCaseInsensitive() {
        let inlines = Markdown.parseInline("HTTP://EXAMPLE.COM/a_b")
        XCTAssertEqual(inlines, [MarkdownInline(text: "HTTP://EXAMPLE.COM/a_b", link: "HTTP://EXAMPLE.COM/a_b")])
    }

    func testBareLinkDoesNotAutolinkInsideCodeOrMarkdownLink() {
        XCTAssertEqual(
            Markdown.parseInline("`https://code.example`"),
            [MarkdownInline(text: "https://code.example", code: true)]
        )
        XCTAssertEqual(
            Markdown.parseInline("[docs](https://docs.example)"),
            [MarkdownInline(text: "docs", link: "https://docs.example")]
        )
    }

    func testMarkdownLinkKeepsBalancedParenthesesInDestination() {
        XCTAssertEqual(
            Markdown.parseInline("[docs](https://example.com/a_(b))"),
            [MarkdownInline(text: "docs", link: "https://example.com/a_(b)")]
        )
    }

    func testBareLinkRequiresTokenBoundary() {
        XCTAssertEqual(
            Markdown.parseInline("prefixhttps://example.com javascript:https://example.com bad\\https://example.com"),
            [MarkdownInline(text: "prefixhttps://example.com javascript:https://example.com bad\\https://example.com")]
        )
    }

    func testUnsafeMarkdownLinkHasNoLinkInInlineModel() {
        XCTAssertEqual(Markdown.parseInline("[run](javascript:alert)"), [MarkdownInline(text: "run")])
    }

    // MARK: - Злые/неполные входы

    func testUnclosedBoldMakesRestBold() {
        // Незакрытый маркер: жирный включается и не выключается — хвост жирный, без краха.
        XCTAssertEqual(Markdown.parseInline("**oops"), [MarkdownInline(text: "oops", bold: true)])
    }

    func testUnclosedCodeIsLiteral() {
        XCTAssertEqual(Markdown.parseInline("`code"), [MarkdownInline(text: "`code")])
    }

    func testUnclosedLinkIsLiteral() {
        XCTAssertEqual(Markdown.parseInline("[text](url"), [MarkdownInline(text: "[text](url")])
    }

    func testEmptyUrlLinkIsLiteral() {
        // `[x]()` — url обязателен (>=1 символ), иначе `[` как обычный текст.
        XCTAssertEqual(Markdown.parseInline("[x]()"), [MarkdownInline(text: "[x]()")])
    }

    func testNestedBoldItalic() {
        // Вложенность **_..._** не должна ронять парсер и даёт bold+italic на содержимом.
        let inlines = Markdown.parseInline("**_hi_**")
        XCTAssertTrue(inlines.contains { $0.text == "hi" && $0.bold && $0.italic })
    }

    // MARK: - Блоки

    func testBulletAndOrderedLists() {
        let blocks = Markdown.parse("- one\n- two\n1. first\n2. second")
        XCTAssertEqual(blocks.map(\.kind), [.bullet, .bullet, .ordered, .ordered])
        XCTAssertEqual(blocks[2].ordinal, 1)
        XCTAssertEqual(blocks[3].ordinal, 2)
    }

    func testHeadingRendersAsBoldParagraph() {
        let blocks = Markdown.parse("# Title\ntext")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .paragraph)
        XCTAssertEqual(blocks[0].inlines, [MarkdownInline(text: "Title", bold: true)], "решётки срезаны, строка жирная")
    }

    // Реальное тело макроса в каноническом виде (2026-10-30): абзацы через пустую строку,
    // H2 из редактора макросов, список и цитата.
    private let macroBody = "Good day,\n\n## Steps\n\n- open the bot\n- press **Stop**\n\n"
        + "> It takes a minute\n\nOlga from Acme Support here.\nThank you for contacting us!"

    func testBlankLineIsParagraphGapOncePerRun() {
        XCTAssertEqual(
            Markdown.parse(macroBody).map(\.kind),
            [.paragraph, .gap, .paragraph, .gap, .bullet, .bullet, .gap, .paragraph, .gap, .paragraph, .paragraph]
        )
        XCTAssertEqual(Markdown.parse("\n\na\n\n\n\nb\n\n").map(\.kind), [.paragraph, .gap, .paragraph])
    }

    func testQuoteLosesMarkerAndNoSyntaxSurvives() {
        let blocks = Markdown.parse(macroBody)
        XCTAssertEqual(blocks[7].inlines.map(\.text).joined(), "It takes a minute")
        let text = String(Markdown.attributedString(from: macroBody).characters)
        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains(">"))
        XCTAssertFalse(text.contains("\\"))
        XCTAssertTrue(text.contains("Good day,\n\nSteps\n\n"), "пустая строка между абзацами сохранена")
        XCTAssertTrue(text.contains("here.\nThank you"), "простой перенос — без пустой строки")
    }

    // Картинка тела макроса — ссылка с подписью alt (пустой alt — адресом), без «!».
    func testImageIsLinkWithoutBang() {
        let inlines = Markdown.parseInline("See ![](https://cdn.example.com/x.png) and ![shot](https://cdn.example.com/a.png)")
        XCTAssertFalse(inlines.map(\.text).joined().contains("!"))
        XCTAssertEqual(inlines.filter { $0.link != nil }, [
            MarkdownInline(text: "https://cdn.example.com/x.png", link: "https://cdn.example.com/x.png"),
            MarkdownInline(text: "shot", link: "https://cdn.example.com/a.png"),
        ])
    }

    // Рыхлый список импорта («1. a\n\n2. b\n\n3. c») держит номера источника, а не «1. 1. 1.»;
    // ленивая нумерация «1. 1.» идёт по порядку, серию рвёт только другой блок.
    func testLooseOrderedListKeepsSourceNumbers() {
        let loose = Markdown.parse("1. Open the bot\n\n2. Press Stop\n\n3. Wait").filter { $0.kind == .ordered }
        XCTAssertEqual(loose.map(\.ordinal), [1, 2, 3])
        let lazy = Markdown.parse("1. a\n1. b\n\ntext\n\n4. c").filter { $0.kind == .ordered }
        XCTAssertEqual(lazy.map(\.ordinal), [1, 2, 4])
    }

    func testEmptySourceYieldsEmptyParagraph() {
        XCTAssertEqual(Markdown.parse(""), [MarkdownBlock(kind: .paragraph, inlines: [MarkdownInline(text: "")])])
    }

    // MARK: - Санитайзинг ссылок

    func testIsSafeLink() {
        XCTAssertTrue(Markdown.isSafeLink("http://a.b"))
        XCTAssertTrue(Markdown.isSafeLink("https://a.b"))
        XCTAssertFalse(Markdown.isSafeLink("javascript:alert(1)"))
        XCTAssertFalse(Markdown.isSafeLink("file:///etc/passwd"))
        XCTAssertFalse(Markdown.isSafeLink("mailto:a@b.c"))
    }

    // MARK: - Рендер в AttributedString

    func testAttributedStringDropsJavascriptLink() {
        let attr = Markdown.attributedString(from: "[click](javascript:alert(1))")
        // Ни один run не должен нести атрибут .link для javascript-схемы.
        for run in attr.runs {
            XCTAssertNil(run.link, "javascript-ссылка не должна быть кликабельной")
        }
        XCTAssertTrue(String(attr.characters).contains("click"))
    }

    func testAttributedStringKeepsHttpsLink() {
        let attr = Markdown.attributedString(from: "[ok](https://respondo.ai)")
        let linked = attr.runs.first { $0.link != nil }
        XCTAssertEqual(linked?.link, URL(string: "https://respondo.ai"))
    }

    func testAttributedStringMarksBold() {
        let attr = Markdown.attributedString(from: "**strong**")
        let bolded = attr.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertNotNil(bolded, "жирный размечен inlinePresentationIntent.stronglyEmphasized")
    }

    func testAttributedStringRendersListMarker() {
        let attr = Markdown.attributedString(from: "- item")
        XCTAssertTrue(String(attr.characters).contains("•"), "маркер списка присутствует в тексте")
    }

    // `\#` в начале строки — литерал `#`, не заголовок: канонический вид тела хранит этот экран
    // (паритет с Android и Flutter).
    func testEscapedHeadingIsPlainText() {
        let blocks = Markdown.parse("\\# of orders: 5\n## Real")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].inlines.map(\.text).joined(), "# of orders: 5")
        XCTAssertFalse(blocks[0].inlines.contains { $0.bold })
        XCTAssertEqual(blocks[1].inlines, [MarkdownInline(text: "Real", bold: true)])
    }
}
