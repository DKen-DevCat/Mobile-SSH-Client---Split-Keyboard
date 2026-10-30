// swift-tools-version: 6.2
// SplitTerm のうち、画面に頼らない部分（docs/design.md「技術スタック」）。
// TermCore: 設定・レイアウト・キーの変換など。依存なし。Mac で `swift test` できる
// TermSession: SSH（swift-nio-ssh）と端末の解釈（SwiftTerm）。アプリから使う
import PackageDescription

let package = Package(
    name: "TermKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TermCore", targets: ["TermCore"]),
        .library(name: "TermSession", targets: ["TermSession"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", .upToNextMinor(from: "0.15.1")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        // 1.99 系は API が動いているので、次の小さな版までに止める
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.99.2")),
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
        .testTarget(name: "TermCoreTests", dependencies: ["TermCore"]),
    ]
)
