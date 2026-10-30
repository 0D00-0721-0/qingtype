// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "QingTypeDependencies",
  platforms: [.macOS(.v14)],
  products: [.library(name: "QingTypeYAML", type: .static, targets: ["QingTypeYAML"])],
  dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "5.0.6")],
  targets: [.target(name: "QingTypeYAML", dependencies: ["Yams"], path: "YAML")]
)
