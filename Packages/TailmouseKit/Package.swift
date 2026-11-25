// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TailmouseKit",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [.library(name: "TailmouseKit", targets: ["TailmouseKit"])],
  targets: [
    .target(name: "TailmouseKit"),
    .testTarget(name: "TailmouseKitTests", dependencies: ["TailmouseKit"]),
  ]
)
