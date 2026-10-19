// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Quill",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "QuillText", targets: ["QuillText"]),
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
            name: "QuillText",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillVim",
            dependencies: ["QuillText"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillLSP",
            dependencies: ["QuillText"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillFS",
            dependencies: ["QuillText"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillSearch",
            dependencies: ["QuillText", "QuillVim"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillMarkdown",
            dependencies: ["QuillText"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillWorkspace",
            dependencies: ["QuillText"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillTOML",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillTextTests",
            dependencies: ["QuillText"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillVimTests",
            dependencies: ["QuillVim", "QuillText"],
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
            dependencies: ["QuillSearch", "QuillVim"],
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
        dependencies: ["QuillText", "QuillVim", "QuillLSP", "QuillFS", "QuillSearch", "QuillMarkdown", "QuillWorkspace", "QuillTOML"],
        path: "Sources/Quill",
        exclude: ["Info.plist"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    )
)
package.targets.append(
    .testTarget(
        name: "QuillAppTests",
        dependencies: ["Quill", "QuillVim", "QuillText", "QuillMarkdown", "QuillLSP", "QuillFS", "QuillSearch"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    )
)
#endif
