// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "FlutterGeneratedPluginSwiftPackage",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "FlutterGeneratedPluginSwiftPackage", type: .static, targets: ["FlutterGeneratedPluginSwiftPackage"])
    ],
    dependencies: [
        .package(name: "app_links", path: "../.packages/app_links-7.2.2"),
        .package(name: "file_picker_darwin", path: "../.packages/file_picker_darwin-2.3.2"),
        .package(name: "firebase_core", path: "../.packages/firebase_core-5.1.0"),
        .package(name: "firebase_messaging", path: "../.packages/firebase_messaging-17.0.1"),
        .package(name: "flutter_secure_storage_darwin", path: "../.packages/flutter_secure_storage_darwin-0.4.3"),
        .package(name: "google_sign_in_ios", path: "../.packages/google_sign_in_ios-6.4.0"),
        .package(name: "in_app_purchase_storekit", path: "../.packages/in_app_purchase_storekit-0.4.15"),
        .package(name: "share_plus", path: "../.packages/share_plus-13.3.1"),
        .package(name: "sqflite_darwin", path: "../.packages/sqflite_darwin-2.4.4+1"),
        .package(name: "url_launcher_ios", path: "../.packages/url_launcher_ios-6.4.2"),
        .package(name: "FlutterFramework", path: "../.packages/FlutterFramework")
    ],
    targets: [
        .target(
            name: "FlutterGeneratedPluginSwiftPackage",
            dependencies: [
                .product(name: "app-links", package: "app_links"),
                .product(name: "file-picker-darwin", package: "file_picker_darwin"),
                .product(name: "firebase-core", package: "firebase_core"),
                .product(name: "firebase-messaging", package: "firebase_messaging"),
                .product(name: "flutter-secure-storage-darwin", package: "flutter_secure_storage_darwin"),
                .product(name: "google-sign-in-ios", package: "google_sign_in_ios"),
                .product(name: "in-app-purchase-storekit", package: "in_app_purchase_storekit"),
                .product(name: "share-plus", package: "share_plus"),
                .product(name: "sqflite-darwin", package: "sqflite_darwin"),
                .product(name: "url-launcher-ios", package: "url_launcher_ios"),
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
