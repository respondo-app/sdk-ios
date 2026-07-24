// swift-tools-version:5.9
import PackageDescription

// Пакет Respondo iOS SDK.
//
// Разбит на два таргета:
//  - RespondoCore — кроссплатформенное ядро (Foundation + Swift Concurrency, без UIKit):
//    транспорт, реалтайм-каскад, идентичность, чат-контроллер, push-разбор, тема, i18n.
//    Собирается и тестируется под macOS (`swift build` / `swift test`).
//  - RespondoSDK — публичный фасад + SwiftUI/UIKit-слой чата. UIKit-код закрыт
//    `#if canImport(UIKit)`, поэтому пакет собирается и на macOS (там UI выключен),
//    а полноценный iOS-UI проверяется через `xcodebuild -destination 'generic/platform=iOS Simulator'`.
let package = Package(
    name: "RespondoSDK",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "RespondoSDK", targets: ["RespondoSDK"]),
        .library(name: "RespondoCore", targets: ["RespondoCore"]),
    ],
    targets: [
        .target(
            name: "RespondoCore",
            path: "Sources/RespondoCore",
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "RespondoSDK",
            dependencies: ["RespondoCore"],
            path: "Sources/RespondoSDK"
        ),
        .testTarget(
            name: "RespondoCoreTests",
            dependencies: ["RespondoCore"],
            path: "Tests/RespondoCoreTests",
            resources: [
                .process("Fixtures"),
            ]
        ),
        .testTarget(
            name: "RespondoSDKTests",
            dependencies: ["RespondoSDK"],
            path: "Tests/RespondoSDKTests"
        ),
    ]
)
