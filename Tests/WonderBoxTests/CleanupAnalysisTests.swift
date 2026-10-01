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

    func testNVMDiscoveryUsesCodexVersionInsteadOfNodeVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (node, codex) in [("v25.2.1", "0.156.1"), ("v22.22.0", "0.159.2"), ("v24.0.0", "0.99.0")] {
            let installation = root.appendingPathComponent(node)
            let bin = installation.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent("codex")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let package = installation.appendingPathComponent("lib/node_modules/@openai/codex")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["version": codex]).write(to: package.appendingPathComponent("package.json"))
        }
        let selected = try XCTUnwrap(CleanupAnalysisSettings.newestNVMExecutable(in: root))
        XCTAssertEqual(Array(URL(fileURLWithPath: selected).pathComponents.suffix(3)), ["v22.22.0", "bin", "codex"])
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

        let apiMessage = "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "error", "status": 400, "error": ["type": "invalid_request_error", "message": apiMessage]]), as: UTF8.self)
        let event = try JSONSerialization.data(withJSONObject: ["type": "turn.failed", "error": ["message": body]])
        do {
            _ = try CleanupAnalysisService.parseOutput(event, exitCode: 1)
            XCTFail("Expected model failure")
        } catch { XCTAssertEqual(error.localizedDescription, apiMessage) }

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

    func testFollowUpPreservesTwoRoundsOfContextAndUsesSelectedSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analysis = try CleanupAnalysisService.parseOutput(Data(outputEvents().utf8), exitCode: 0)
        let answer = CleanupFollowUpResult(answer: "LocalHistory needs a backup", sources: [.init(title: "Local history", url: "https://example.com/history")])
        let events = try events(for: answer, includeSearch: true)
        let cli = try fakeCLI(in: directory, body: """
        printf '%s\\n' "$@" > "$0.args"
        cat > "$0.prompt"
        printf '%s' '\(events)'
        """)
        let question = "Can I restore \"LocalHistory\"?\nDo I need a backup?"
        var settings = CleanupAnalysisSettings(executablePath: cli.path, model: "chosen-model", effort: "high")
        let first = try await CleanupAnalysisService().followUp(summary: fixtureSummary, analysis: analysis, history: [], question: question, settings: settings)
        XCTAssertEqual(first.result.answer, answer.answer)
        XCTAssertEqual(first.result.sources.first?.url, "https://example.com/history")
        XCTAssertTrue(first.usedWebSearch)
        let firstContext = try followUpContext(cli: cli)
        XCTAssertEqual(firstContext["currentQuestion"] as? String, question)
        XCTAssertEqual((firstContext["previousExchanges"] as? [Any])?.count, 0)
        let summary = try XCTUnwrap(firstContext["summary"] as? [String: Any])
        XCTAssertEqual(summary["path"] as? String, fixtureSummary.path)
        XCTAssertEqual(summary["deletionMethod"] as? String, "permanentDeletion")
        let initial = try XCTUnwrap(firstContext["initialAnalysis"] as? [String: Any])
        XCTAssertEqual((initial["result"] as? [String: Any])?["verdict"] as? String, analysis.result.verdict)
        var arguments = try String(contentsOf: URL(fileURLWithPath: cli.path + ".args"), encoding: .utf8)
        for expected in ["chosen-model", "model_reasoning_effort=high", "web_search=live", "read-only", "--ephemeral", "--output-schema"] {
            XCTAssertTrue(arguments.contains(expected), expected)
        }

        settings.effort = "xhigh"
        let secondQuestion = "How should I make that backup?"
        let second = try await CleanupAnalysisService().followUp(summary: fixtureSummary, analysis: analysis, history: [.init(question: question, response: first)], question: secondQuestion, settings: settings)
        XCTAssertEqual(second.result.answer, answer.answer)
        let secondContext = try followUpContext(cli: cli)
        XCTAssertEqual(secondContext["currentQuestion"] as? String, secondQuestion)
        let history = try XCTUnwrap(secondContext["previousExchanges"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?["question"] as? String, question)
        let previous = try XCTUnwrap(history.first?["response"] as? [String: Any])
        XCTAssertEqual((previous["result"] as? [String: Any])?["answer"] as? String, first.result.answer)
        arguments = try String(contentsOf: URL(fileURLWithPath: cli.path + ".args"), encoding: .utf8)
        XCTAssertTrue(arguments.contains("model_reasoning_effort=xhigh"))
    }

    func testFollowUpFailureCancellationTimeoutAndSearchObservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analysis = try CleanupAnalysisService.parseOutput(Data(outputEvents().utf8), exitCode: 0)
        let failed = try fakeCLI(in: directory, body: "cat >/dev/null\nprintf '%s\\n' '{\"type\":\"turn.failed\",\"error\":{\"message\":\"quota exceeded\"}}'\nexit 1")
        do {
            _ = try await CleanupAnalysisService().followUp(summary: fixtureSummary, analysis: analysis, history: [], question: "Can I recover it?", settings: .init(executablePath: failed.path))
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error.localizedDescription, "quota exceeded") }

        let waiting = try fakeCLI(in: directory, body: "cat >/dev/null\nexec /bin/sleep 20")
        let task = Task {
            try await CleanupAnalysisService().followUp(summary: fixtureSummary, analysis: analysis, history: [], question: "Can I recover it?", settings: .init(executablePath: waiting.path))
        }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 5)
        do {
            _ = try await CleanupAnalysisService().followUp(summary: fixtureSummary, analysis: analysis, history: [], question: "Can I recover it?", settings: .init(executablePath: waiting.path), timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error is CleanupAnalysisError) }

        let events = try events(for: CleanupFollowUpResult(answer: "A backup is needed", sources: []), includeSearch: false)
        let noSearch = try fakeCLI(in: directory, body: "cat >/dev/null\nprintf '%s' '\(events)'")
        let response = try await CleanupAnalysisService().followUp(summary: fixtureSummary, analysis: analysis, history: [], question: "Can I recover it?", settings: .init(executablePath: noSearch.path))
        XCTAssertFalse(response.usedWebSearch)
    }

    private func followUpContext(cli: URL) throws -> [String: Any] {
        let prompt = try String(contentsOf: URL(fileURLWithPath: cli.path + ".prompt"), encoding: .utf8)
        XCTAssertTrue(prompt.contains("Correct earlier mistakes"))
        let payload = try XCTUnwrap(prompt.components(separatedBy: "Conversation context:\n").last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
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
        return try events(for: result, includeSearch: includeSearch)
    }

    private func events<T: Encodable>(for result: T, includeSearch: Bool) throws -> String {
        let resultText = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        var events: [[String: Any]] = []
        if includeSearch { events.append(["type": "item.completed", "item": ["type": "web_search"]]) }
        events.append(["type": "item.completed", "item": ["type": "agent_message", "text": resultText]])
        events.append(["type": "turn.completed"])
        return try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }
}
