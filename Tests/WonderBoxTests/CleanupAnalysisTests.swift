import Foundation
import XCTest
@testable import WonderBox

final class CleanupAnalysisTests: XCTestCase {
    func testSummaryDescribesWholeDeletionWithoutReadingFilesOrFollowingLinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Caches/JetBrains")
        let history = root.appendingPathComponent("GoLand2026.2/LocalHistory")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("PRIVATE_CONTENT_DO_NOT_SEND".utf8).write(to: history.appendingPathComponent("private-project.txt"))
        let outside = home.appendingPathComponent("private-outside")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("secret-directory"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)

        let item = CleanupItem(url: root, size: 12_000, isSelected: true, isDirectory: true)
        let summary = CleanupAnalysisService.makeSummary(item: item, kind: .caches, home: home, applicationRoots: [])
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        XCTAssertEqual(summary.path, "~/Library/Caches/JetBrains")
        XCTAssertEqual(summary.deletionMethod, .permanentDeletion)
        XCTAssertEqual(summary.directories, ["GoLand2026.2", "GoLand2026.2/LocalHistory"])
        XCTAssertFalse(json.contains(home.path))
        XCTAssertFalse(json.contains("private-project"))
        XCTAssertFalse(json.contains("PRIVATE_CONTENT"))
        XCTAssertFalse(json.contains("secret-directory"))
        XCTAssertEqual(CleanupAnalysisService.makeSummary(item: item, kind: .installers, home: home, applicationRoots: []).deletionMethod, .moveToTrash)
        XCTAssertEqual(CleanupAnalysisService.makeSummary(item: item, kind: .trash, home: home, applicationRoots: []).deletionMethod, .emptyEntireTrash)
    }

    func testSummaryFindsApplicationVersionAndLimitsDirectoryDepth() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Caches/JetBrains")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("GoLand2026.2/index/private-project"), withIntermediateDirectories: true)
        let apps = home.appendingPathComponent("Applications")
        let contents = apps.appendingPathComponent("GoLand.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleName": "GoLand", "CFBundleIdentifier": "com.jetbrains.goland", "CFBundleShortVersionString": "2026.2"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let item = CleanupItem(url: root, size: 0, isSelected: false, isDirectory: true, isSizeEstimated: false)
        let summary = CleanupAnalysisService.makeSummary(item: item, kind: .caches, home: home, applicationRoots: [apps])
        XCTAssertEqual(summary.applications.first?.name, "GoLand")
        XCTAssertEqual(summary.applications.first?.version, "2026.2")
        XCTAssertFalse(summary.directories.contains { $0.contains("private-project") })
        XCTAssertNil(summary.sizeBytes)
    }
}
