// swift-tools-version: 6.2
// Mobile-SSH-Client---Split-Keyboard（内部の短い名前は SplitTerm）のうち、画面に頼らず、外の依存を持つ部分
// （docs/design.md「技術スタック」）。依存の無い TermCore は ../TermCore にある
// TermSession: SSH（swift-nio-ssh）と端末の解釈（SwiftTerm）。アプリから使う
// TermKana: かな漢字変換（AzooKey）。辞書が大きいので、ほかと分ける
import PackageDescription

let package = Package(
    name: "TermKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TermSession", targets: ["TermSession"]),
        .library(name: "TermKana", targets: ["TermKana"]),
    ],
    dependencies: [
        .package(path: "../TermCore"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", .upToNextMinor(from: "0.15.1")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        // SwiftTerm が保守するのは最新版だけ（SECURITY.md）。ふだんは最新に追従する。
        // 一時的に 1.99.1 に止めている: 1.99.2（2026-10-29）の PowerlineRenderer.swift:386 が Xcode 26.3（Swift 6.2.4）で
        // コンパイルできない（#774 で入った式。1.99.1 には無い。使っている API は同じ）。直った版が出たら最新に戻す
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.1"),
        // 1.0 までは小さな版で壊れる変更がありうる（README の指示どおり upToNextMinor）
        .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter.git", .upToNextMinor(from: "0.11.2")),
    ],
    targets: [
        .target(
            name: "TermSession",
            dependencies: [
                .product(name: "TermCore", package: "TermCore"),
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
                .product(name: "TermCore", package: "TermCore"),
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
            ],
            // 変換器（KanaKanjiConverter）は Sendable でないので、1 本のキューに閉じ込めて使う
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
