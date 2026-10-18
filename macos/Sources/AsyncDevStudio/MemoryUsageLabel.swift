import SwiftUI
import StudioPlatform

struct MemoryUsageLabel: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let megabytes = ProcessMemory.currentFootprintBytes().map { Double($0) / 1_000_000 }
            Group {
                if let megabytes {
                    Text("Memory: \(megabytes, specifier: "%.1f") MB")
                } else {
                    Text("Memory: unavailable")
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Current app process memory, updated every two seconds. Separate browser and terminal processes are not included.")
        }
    }
}
