import SwiftUI

struct CleanupAnalysisSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: CleanupItem
    let kind: CleanupKind
    @State private var summary: CleanupAnalysisSummary?
    @State private var response: CleanupAnalysisResponse?
    @State private var exchanges: [CleanupFollowUpExchange] = []
    @State private var question = ""
    @State private var showingSummary = false
    @State private var errorMessage: String?
    @State private var analysisTask: Task<Void, Never>?
    @AppStorage("cleanupCodexPath") private var codexPath = ""
    @AppStorage("cleanupCodexModel") private var codexModel = "gpt-6.1-sol"
    @AppStorage("cleanupCodexEffort") private var codexEffort = "medium"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Cleanup Impact").font(.title2.bold())
                Spacer()
                Button("Done") { analysisTask?.cancel(); dismiss() }
            }
            Text("AI analysis sends the directory summary, your questions and previous answers to Codex and may use your subscription allowance. File contents are not read automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    if let response, !showingSummary {
                        VStack(alignment: .leading, spacing: 20) {
                            resultView(response)
                            ForEach(Array(exchanges.enumerated()), id: \.offset) { _, exchange in
                                exchangeView(exchange)
                            }
                            Color.clear.frame(height: 1).id("conversation-end")
                        }
                    } else if let summary {
                        Text(summary.preview)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ProgressView("Preparing directory summary…")
                    }
                }
                .onChange(of: exchanges.count) { _, _ in
                    reader.scrollTo("conversation-end", anchor: .bottom)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if response != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ask a follow-up question").font(.callout)
                    HStack(alignment: .bottom, spacing: 12) {
                        TextEditor(text: $question)
                            .font(.callout)
                            .frame(height: 62)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                            .accessibilityLabel("Follow-up question")
                            .disabled(analysisTask != nil)
                        Button("Send", action: sendFollowUp)
                            .buttonStyle(.borderedProminent)
                            .disabled(analysisTask != nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(codexModel) · \(codexEffort)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if analysisTask != nil {
                    ProgressView().controlSize(.small)
                    Text("Analyzing with Codex…").font(.callout)
                    Button("Cancel") { analysisTask?.cancel() }
                } else {
                    if response != nil {
                        Button(showingSummary ? String(localized: "View Analysis") : String(localized: "View Summary")) {
                            showingSummary.toggle()
                        }
                    }
                    Button(response == nil ? String(localized: "Start Analysis") : String(localized: "Analyze Again"), action: startAnalysis)
                        .buttonStyle(.borderedProminent)
                        .disabled(summary == nil)
                }
            }
        }
        .padding(24)
        .frame(width: 740, height: 580)
        .task {
            let collected = await Task.detached(priority: .utility) {
                CleanupAnalysisService.makeSummary(item: item, kind: kind)
            }.value
            if !Task.isCancelled { summary = collected }
        }
        .onDisappear { analysisTask?.cancel() }
    }

    private func startAnalysis() {
        guard analysisTask == nil, let summary else { return }
        let settings = CleanupAnalysisSettings(executablePath: codexPath, model: codexModel, effort: codexEffort)
        performRequest {
            let result = try await CleanupAnalysisService().analyze(summary: summary, settings: settings)
            try Task.checkCancellation()
            response = result
            exchanges = []
            question = ""
            showingSummary = false
        }
    }

    private func sendFollowUp() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard analysisTask == nil, let summary, let response, !asked.isEmpty else { return }
        let settings = CleanupAnalysisSettings(executablePath: codexPath, model: codexModel, effort: codexEffort)
        let history = exchanges
        performRequest {
            let answer = try await CleanupAnalysisService().followUp(summary: summary, analysis: response, history: history, question: asked, settings: settings)
            try Task.checkCancellation()
            exchanges.append(.init(question: asked, response: answer))
            question = ""
            showingSummary = false
        }
    }

    private func performRequest(_ operation: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        analysisTask = Task {
            defer { analysisTask = nil }
            do {
                try await operation()
            } catch is CancellationError {
                // Keep the completed report, conversation and draft available for a manual retry.
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private func resultView(_ response: CleanupAnalysisResponse) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            searchStatus(response.usedWebSearch)
            Text(response.result.verdict).font(.headline)
            ForEach(Array(response.result.entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.path).font(.headline)
                    Text(entry.purpose)
                    Text(entry.impact)
                    Text(entry.recovery).foregroundStyle(.secondary)
                }
            }
            Text("Recommendation").font(.headline)
            Text(response.result.recommendation)
            Text("Uncertainty").font(.headline)
            Text(response.result.uncertainty)
            sourcesView(response.result.sources)
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exchangeView(_ exchange: CleanupFollowUpExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Your Question").font(.headline)
            Text(exchange.question)
            Text("AI Answer").font(.headline)
            searchStatus(exchange.response.usedWebSearch)
            Text(exchange.response.result.answer)
            sourcesView(exchange.response.result.sources)
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func searchStatus(_ searched: Bool) -> some View {
        Text(searched ? String(localized: "Web search used") : String(localized: "No web search was observed; this result is not verified online."))
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func sourcesView(_ sources: [CleanupAnalysisResult.Source]) -> some View {
        if !sources.isEmpty {
            Text("Sources").font(.headline)
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                if let link = source.link { Link(source.title, destination: link) }
            }
        }
    }
}
