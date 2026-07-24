import XCTest
@testable import RespondoCore

final class OverlayArbiterTests: XCTestCase {
    private func survey(_ id: String) -> RespondoSurvey {
        RespondoSurvey(
            campaignId: "camp-\(id)", deliveryId: id, name: "s", format: .inModal,
            intro: nil, thanks: nil, showIntroScreen: false, showProgress: false, showDismiss: true,
            steps: [["q1"]], questions: [RespondoQuestion(id: "q1", type: .nps, title: "?", options: [], required: false)], sender: nil
        )
    }

    private func banner(_ id: String) -> RespondoBanner {
        RespondoBanner(
            campaignId: "camp-\(id)", deliveryId: id, name: "b", body: "hi",
            layout: .floating, position: .bottom, action: .url, url: URL(string: "https://x.y"),
            linkLabel: "go", reactions: [], openNewTab: true, backgroundHex: nil, foregroundHex: nil,
            buttonBackgroundHex: nil, buttonForegroundHex: nil, dismissAfterAction: false, showDismiss: true, sender: nil
        )
    }

    func testSurveyBeatsBanner() {
        let decision = OverlayArbiter.decide(OverlayArbiterInput(
            surveys: [survey("s1")], banners: [banner("b1")], dismissed: [], lightboxOpen: false, composerHasText: false
        ))
        XCTAssertEqual(decision, .survey(survey("s1")))
    }

    func testBannerWhenNoSurvey() {
        let decision = OverlayArbiter.decide(OverlayArbiterInput(
            surveys: [], banners: [banner("b1")], dismissed: [], lightboxOpen: false, composerHasText: false
        ))
        XCTAssertEqual(decision, .banner(banner("b1")))
    }

    func testLightboxSuppresses() {
        let decision = OverlayArbiter.decide(OverlayArbiterInput(
            surveys: [survey("s1")], banners: [banner("b1")], dismissed: [], lightboxOpen: true, composerHasText: false
        ))
        XCTAssertEqual(decision, .none)
    }

    func testComposerTextSuppresses() {
        let decision = OverlayArbiter.decide(OverlayArbiterInput(
            surveys: [survey("s1")], banners: [], dismissed: [], lightboxOpen: false, composerHasText: true
        ))
        XCTAssertEqual(decision, .none)
    }

    func testDismissedSkipped() {
        let decision = OverlayArbiter.decide(OverlayArbiterInput(
            surveys: [survey("s1")], banners: [banner("b1")], dismissed: ["s1"], lightboxOpen: false, composerHasText: false
        ))
        XCTAssertEqual(decision, .banner(banner("b1")))
    }

    func testAllDismissedGivesNone() {
        let decision = OverlayArbiter.decide(OverlayArbiterInput(
            surveys: [survey("s1")], banners: [banner("b1")], dismissed: ["s1", "b1"], lightboxOpen: false, composerHasText: false
        ))
        XCTAssertEqual(decision, .none)
    }
}
