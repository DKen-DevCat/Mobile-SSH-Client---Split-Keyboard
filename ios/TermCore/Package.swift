// swift-tools-version: 6.2
// Mobile-SSH-Client---Split-Keyboard の、依存を持たない部分（docs/design.md「技術スタック」）。
// TermCore: 設定・レイアウト・キーの変換など。アプリ（ios/SplitTerm）と TermKit が使う
// splitterm: Mac で動くコマンドと MCP サーバー（config の検査・変更・送信、端末への入れ直し、受け取り箱）。
//   同じ TermCore で config を読むので、アプリと検査の規則がずれない。依存が無いので数秒でビルドできる:
//   swift build -c release --package-path ios/TermCore
import PackageDescription

let package = Package(
    name: "TermCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "TermCore", targets: ["TermCore"]),
        .executable(name: "splitterm", targets: ["splitterm"]),
    ],
    targets: [
        .target(name: "TermCore"),
        .executableTarget(
            name: "splitterm",
            dependencies: ["TermCore"],
            // Process と標準入出力を素直に使う。Swift 6 の厳密な検査は Mac でビルドを通してから
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "TermCoreTests", dependencies: ["TermCore"]),
        .testTarget(name: "SplittermTests", dependencies: ["splitterm", "TermCore"]),
    ]
)
