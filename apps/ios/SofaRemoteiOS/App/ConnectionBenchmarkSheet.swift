import AppleCore
import SwiftUI

struct ConnectionBenchmarkSheet: View {
    @Bindable var model: RemoteModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("Authenticated round trips", systemImage: "arrow.left.arrow.right")
                    .font(.title3.weight(.semibold))
                Text(
                    "Measure 3 groups of 30 sequential no-op probes over "
                        + "\(model.selectedTransport.rawValue). No pointer or audio commands are sent."
                )
                .foregroundStyle(.secondary)
                if model.benchmarkRunning {
                    ProgressView(value: Double(model.benchmarkProgress), total: 90)
                    Text(
                        "\(model.benchmarkProgress) / 90 probes · \(model.benchmarkGroupProgress)"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                if let result = model.benchmarkResultText {
                    Text(result).font(.callout.monospaced()).textSelection(.enabled)
                }
                if let target = model.benchmarkTargetID,
                    let reports = model.benchmarkReports[target], !reports.isEmpty
                {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latest results for this Mac")
                            .font(.headline)
                        ForEach(reports, id: \.transport) { report in
                            Text(model.benchmarkSummary(report))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityIdentifier("benchmark.comparison")
                }
                Button(model.benchmarkRunning ? "Cancel benchmark" : "Run benchmark") {
                    if model.benchmarkRunning {
                        model.cancelBenchmark()
                    } else {
                        model.startBenchmark()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !model.benchmarkRunning && (!model.isConnected || !model.supportsRoundTripProbe)
                )
                if !model.supportsRoundTripProbe {
                    Text(
                        "This Mac does not advertise round-trip probe support. "
                            + "Update the Mac companion to run this benchmark."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
