// swift-tools-version: 6.2
// SplitTerm のうち、画面に頼らない部分（docs/design.md「技術スタック」）。
// TermCore: 設定・レイアウト・キーの変換など。依存なし。Mac で `swift test` できる
// TermSession: SSH（swift-nio-ssh）と端末の解釈（SwiftTerm）。アプリから使う
// TermKana: かな漢字変換（AzooKey）。辞書が大きいので、ほかと分ける
import PackageDescription

let package = Package(
    name: "TermKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TermCore", targets: ["TermCore"]),
        .library(name: "TermSession", targets: ["TermSession"]),
        .library(name: "TermKana", targets: ["TermKana"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", .upToNextMinor(from: "0.15.1")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        // SwiftTerm が保守するのは最新版だけ（SECURITY.md）。1.99 系（2.0 の API）は動いているので、次の小さな版までに止め、
        // 新しい版が出たら上げる
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.99.2")),
        // 1.0 までは小さな版で壊れる変更がありうる（README の指示どおり upToNextMinor）
        .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter.git", .upToNextMinor(from: "0.11.2")),
    ],
    targets: [
        .target(name: "TermCore"),
        .target(
            name: "TermSession",
            dependencies: [
                "TermCore",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            // NIO のハンドラは Sendable でないものを EventLoop の上で扱う。Swift 6 の厳密な検査は
            // Mac でビルドを通してから段階的に入れる（docs/design.md「未決事項」）
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TermKana",
            dependencies: [
                "TermCore",
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
            ],
            // 変換器（KanaKanjiConverter）は Sendable でないので、1 本のキューに閉じ込めて使う
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "TermCoreTests", dependencies: ["TermCore"]),
    ]
)
