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

    func testHeadingRendersAsParagraph() {
        let blocks = Markdown.parse("# Title\ntext")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .paragraph)
        XCTAssertEqual(blocks[0].inlines, [MarkdownInline(text: "Title")], "решётки заголовка срезаны")
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
}
