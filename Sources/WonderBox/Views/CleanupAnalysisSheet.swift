import SwiftUI

struct CleanupAnalysisSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: CleanupItem
    let kind: CleanupKind
    @State private var summary: CleanupAnalysisSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Cleanup Impact").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("AI analysis sends this directory summary to Codex and may use your subscription allowance. File contents are not sent.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                if let summary {
                    Text(summary.preview)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView("Preparing directory summary…")
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
    }
}
