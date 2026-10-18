// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Quill",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "QuillVim", targets: ["QuillVim"]),
        .library(name: "QuillLSP", targets: ["QuillLSP"]),
        .library(name: "QuillFS", targets: ["QuillFS"]),
        .library(name: "QuillSearch", targets: ["QuillSearch"]),
        .library(name: "QuillMarkdown", targets: ["QuillMarkdown"]),
        .library(name: "QuillWorkspace", targets: ["QuillWorkspace"]),
        .library(name: "QuillTOML", targets: ["QuillTOML"]),
    ],
    targets: [
        .target(
            name: "QuillVim",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillLSP",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillFS",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillSearch",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillMarkdown",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillWorkspace",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillTOML",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillVimTests",
            dependencies: ["QuillVim"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillLSPTests",
            dependencies: ["QuillLSP"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillFSTests",
            dependencies: ["QuillFS"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillSearchTests",
            dependencies: ["QuillSearch"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillMarkdownTests",
            dependencies: ["QuillMarkdown"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillWorkspaceTests",
            dependencies: ["QuillWorkspace"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillTOMLTests",
            dependencies: ["QuillTOML"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

#if os(macOS)
package.products.append(
    .executable(name: "Quill", targets: ["Quill"])
)
package.targets.append(
    .executableTarget(
        name: "Quill",
        dependencies: ["QuillVim", "QuillLSP", "QuillFS", "QuillSearch", "QuillMarkdown", "QuillWorkspace", "QuillTOML"],
        path: "Sources/Quill",
        exclude: ["Info.plist"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    )
)
#endif
