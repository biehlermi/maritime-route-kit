// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "MaritimeRouteKit",
  platforms: [
    .iOS(.v26)
  ],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "MaritimeRouteKit",
      targets: ["MaritimeRouteKit"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(
      name: "MaritimeRouteKit",
      resources: [
        .process("Resources")
      ],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ],
    ),
    .testTarget(
      name: "MaritimeRouteKitTests",
      dependencies: ["MaritimeRouteKit"],
      resources: [
        .process("Resources")
      ],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ],
    ),
  ]
)
