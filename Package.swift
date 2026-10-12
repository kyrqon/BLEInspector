// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "BLEInspectorCore",
    platforms: [.iOS("26.0"), .macOS(.v13)],
    products: [.library(name:"BLEInspectorCore",targets:["BLEInspectorCore"])],
    targets: [
        .target(name:"BLEInspectorCore",path:"Sources",exclude:["App.swift","Bluetooth.swift"]),
        .testTarget(name:"BLEInspectorCoreTests",dependencies:["BLEInspectorCore"],path:"Tests")
    ]
)
