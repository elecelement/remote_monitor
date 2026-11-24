import SwiftUI
import WorkbenchCore

struct GPUSection: View {
    let snapshot: GPUSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("显卡监控", systemImage: "cpu").font(.title3.weight(.semibold))
                Spacer()
                if let snapshot {
                    Image(systemName: snapshot.online ? "circle.fill" : "circle")
                        .font(.system(size: 7)).foregroundStyle(snapshot.online ? Color.teal : .secondary)
                    Text(snapshot.online ? "已连接" : "已离线").font(.caption)
                    if let date = snapshot.sampledAt {
                        Text("·").foregroundStyle(.tertiary)
                        Text("采样 \(date.formatted(date: .omitted, time: .standard))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if let snapshot {
                if let error = snapshot.error { Notice(text: error) }
                if !snapshot.readings.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(snapshot.readings) { gpu in GPUCard(gpu: gpu, stale: snapshot.error != nil) }
                    }
                } else if snapshot.error == nil {
                    Text("当前驱动没有报告可见的 NVIDIA 显卡。")
                        .foregroundStyle(.secondary).padding(.vertical, 10)
                }
            } else {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在读取显卡状态…") }
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
            }
        }
    }
}

private struct GPUCard: View {
    let gpu: GPUReading
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("GPU \(gpu.index)").font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if stale { Text("上次读数").font(.caption2).foregroundStyle(.secondary) }
            }
            Text(gpu.name).font(.headline).lineLimit(2)
            VStack(spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("利用率").foregroundStyle(.secondary)
                    Spacer()
                    Text(gpu.utilization.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                        .font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                }
                meter(gpu.utilization.map { $0 / 100 }, color: .teal)
            }
            VStack(spacing: 7) {
                HStack {
                    Text("显存").foregroundStyle(.secondary)
                    Spacer()
                    Text(memoryText).font(.caption.monospacedDigit())
                }
                meter(memoryRatio, color: .blue)
            }
        }.font(.caption).padding(16)
            .background(WorkbenchStyle.panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.07)) }
    }

    private var memoryText: String {
        guard let used = gpu.memoryUsed, let total = gpu.memoryTotal else { return "—" }
        return "\(memoryAmount(used)) / \(memoryAmount(total))"
    }

    private func memoryAmount(_ mib: Double) -> String {
        guard mib.isFinite, mib >= 0 else { return "—" }
        if mib > 0 && mib < 1 { return "<1 MiB" }
        if mib < 1024 {
            return mib.formatted(.number.precision(.fractionLength(0...1))) + " MiB"
        }
        return (mib / 1024).formatted(.number.precision(.fractionLength(0...1))) + " GiB"
    }
    private var memoryRatio: Double? {
        guard let used = gpu.memoryUsed, let total = gpu.memoryTotal, total > 0 else { return nil }
        return used / total
    }

    private func meter(_ ratio: Double?, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                if let ratio, ratio.isFinite {
                    Capsule().fill(stale ? Color.secondary : color)
                        .frame(width: proxy.size.width * max(0, min(ratio, 1)))
                }
            }
        }.frame(height: 4).accessibilityHidden(true)
    }
}
