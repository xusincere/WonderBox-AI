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

    func testCodexInvocationAndStructuredResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try outputEvents()
        let split = events.index(events.startIndex, offsetBy: 17)
        let cli = try fakeCLI(in: directory, body: """
        printf '%s\\n' "$@" > "$0.args"
        cat > "$0.prompt"
        printf '%s' '\(events[..<split])'
        printf '%s' '\(events[split...])'
        """)
        let response = try await CleanupAnalysisService().analyze(summary: fixtureSummary, settings: .init(executablePath: cli.path))
        XCTAssertTrue(response.usedWebSearch)
        XCTAssertEqual(response.result.entries.first?.path, "LocalHistory")
        XCTAssertTrue(response.result.verdict.contains("history"))
        let arguments = try String(contentsOf: URL(fileURLWithPath: cli.path + ".args"), encoding: .utf8)
        for expected in ["gpt-6.1-sol", "model_reasoning_effort=medium", "web_search=live", "read-only", "--ephemeral", "--output-schema", "shell_tool", "--ignore-user-config"] {
            XCTAssertTrue(arguments.contains(expected), expected)
        }
        let prompt = try String(contentsOf: URL(fileURLWithPath: cli.path + ".prompt"), encoding: .utf8)
        XCTAssertTrue(prompt.contains("~/Library/Caches/JetBrains"))
        XCTAssertTrue(prompt.contains("permanentDeletion"))
        XCTAssertTrue(prompt.contains("cannot exclude a subdirectory"))
    }

    func testFailureCancellationAndTimeoutFinish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = try fakeCLI(in: directory, body: "cat >/dev/null\nprintf '%s\\n' '{\"type\":\"turn.failed\",\"error\":{\"message\":\"quota exceeded\"}}'\nexit 1")
        do {
            _ = try await CleanupAnalysisService().analyze(summary: fixtureSummary, settings: .init(executablePath: failed.path))
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error.localizedDescription, "quota exceeded") }

        let waiting = try fakeCLI(in: directory, body: "cat >/dev/null\nexec /bin/sleep 20")
        let task = Task {
            try await CleanupAnalysisService().analyze(summary: fixtureSummary, settings: .init(executablePath: waiting.path))
        }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 5)

        do {
            _ = try await CleanupAnalysisService().analyze(summary: fixtureSummary, settings: .init(executablePath: waiting.path), timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error is CleanupAnalysisError) }
    }

    func testIncompleteOutputIsRejectedAndNoSearchIsReportedHonestly() throws {
        let data = try outputEvents(includeSearch: false)
        let response = try CleanupAnalysisService.parseOutput(Data(data.utf8), exitCode: 0)
        XCTAssertFalse(response.usedWebSearch)
        do {
            _ = try CleanupAnalysisService.parseOutput(Data("{\"type\":\"turn.completed\"}\n".utf8), exitCode: 0)
            XCTFail("Expected incomplete output failure")
        } catch { XCTAssertTrue(error is CleanupAnalysisError) }
    }

    private var fixtureSummary: CleanupAnalysisSummary {
        .init(path: "~/Library/Caches/JetBrains", category: "App Caches", deletionMethod: .permanentDeletion, sizeBytes: 12_000, directories: ["GoLand2026.2/LocalHistory"], applications: [], notes: [])
    }

    private func fakeCLI(in directory: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-codex-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func outputEvents(includeSearch: Bool = true) throws -> String {
        let result = CleanupAnalysisResult(verdict: "Deleting this directory loses local history", entries: [.init(path: "LocalHistory", purpose: "Local edits", impact: "History is lost", recovery: "Cannot rebuild history")], recommendation: "Use the IDE cleanup", uncertainty: "Custom paths are unknown", sources: [.init(title: "Documentation", url: "https://example.com/docs")])
        let resultText = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        var events: [[String: Any]] = []
        if includeSearch { events.append(["type": "item.completed", "item": ["type": "web_search"]]) }
        events.append(["type": "item.completed", "item": ["type": "agent_message", "text": resultText]])
        events.append(["type": "turn.completed"])
        return try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }
}
