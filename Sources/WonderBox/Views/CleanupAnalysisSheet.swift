import SwiftUI

struct CleanupAnalysisSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: CleanupItem
    let kind: CleanupKind
    @State private var summary: CleanupAnalysisSummary?
    @State private var response: CleanupAnalysisResponse?
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
            Text("AI analysis sends this directory summary to Codex and may use your subscription allowance. File contents are not sent.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                if let response {
                    resultView(response)
                } else if let summary {
                    Text(summary.preview)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView("Preparing directory summary…")
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
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
                        Button("View Summary") { response = nil }
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
        errorMessage = nil
        response = nil
        let settings = CleanupAnalysisSettings(executablePath: codexPath, model: codexModel, effort: codexEffort)
        analysisTask = Task {
            defer { analysisTask = nil }
            do {
                let result = try await CleanupAnalysisService().analyze(summary: summary, settings: settings)
                if !Task.isCancelled { response = result }
            } catch is CancellationError {
                // Cancellation returns to the preview, ready for another manual attempt.
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private func resultView(_ response: CleanupAnalysisResponse) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(response.usedWebSearch ? String(localized: "Web search used") : String(localized: "No web search was observed; this result is not verified online."))
                .font(.caption).foregroundStyle(.secondary)
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
            if !response.result.sources.isEmpty {
                Text("Sources").font(.headline)
                ForEach(Array(response.result.sources.enumerated()), id: \.offset) { _, source in
                    if let link = source.link { Link(source.title, destination: link) }
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
