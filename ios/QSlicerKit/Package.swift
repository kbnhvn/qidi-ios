// swift-tools-version:5.9
// Paquet de test du Swift « pur » (sans UIKit/SceneKit) : les sources sont celles de
// l'app, liées par des liens symboliques. Il se compile et se teste sous Linux
// (gratuit en CI), ce qui évite de réserver un runner macOS pour la logique.
//
//     cd ios/QSlicerKit && swift test
import PackageDescription

let package = Package(
    name: "QSlicerKit",
    products: [.library(name: "QSlicerKit", targets: ["QSlicerKit"])],
    targets: [
        .target(name: "QSlicerKit"),
        .testTarget(name: "QSlicerKitTests", dependencies: ["QSlicerKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
