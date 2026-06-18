import Foundation
import MemorySentry

/// 把 MemorySentry 的 observer 回调桥接到 SwiftUI。
///
/// 注意：MemorySentry 的 observer 回调在内部串行队列触发，不保证主线程，
/// 因此 EventBridge 内部用 `MainActor.run` 切回主线程再发布到 `@Published`。
@MainActor
final class EventBridge: ObservableObject {
    static let shared = EventBridge()

    /// 最近 N 条事件日志，用于 UI 展示（最新在前）。
    @Published var log: [String] = []
    /// 最近一次现场快照摘要（字节阈值告警附带）。
    @Published var lastSnapshot: String?

    private nonisolated init() {}

    private static let maxLogCount = 30

    private func appendLog(_ line: String) {
        log.insert(line, at: 0)
        if log.count > Self.maxLogCount {
            log.removeLast()
        }
    }

    nonisolated private static func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1024 / 1024)
    }
}

extension EventBridge: MemorySentryObserver {
    nonisolated func memorySentry(didExceedAppFootprint event: AppFootprintEvent) {
        let line = "🟠 footprint=\(Self.mb(event.footprint))MB > threshold=\(Self.mb(event.threshold))MB"
        let summary = event.snapshot?.diagnosticSummary()
        Task { @MainActor in
            self.appendLog(line)
            if let summary { self.lastSnapshot = summary }
        }
    }

    nonisolated func memorySentry(didCrossMemoryPressure event: MemoryPressureEvent) {
        let icon = event.level == .critical ? "🛑" : "⚠️"
        let line = "\(icon) pressure \(event.level.rawValue) ratio=\(String(format: "%.1f", event.ratio * 100))% threshold=\(String(format: "%.1f", event.threshold * 100))% (\(Self.mb(event.footprint))MB / \(Self.mb(event.limit))MB)"
        Task { @MainActor in
            self.appendLog(line)
        }
    }

    nonisolated func memorySentry(didReceiveMetricKitPayload event: MetricKitEvent) {
        let line = "📦 MetricKit \(event.eventType.rawValue) peak=\(event.peakMemoryUsage.map(Self.mb) ?? "-")MB frames=\(event.callStack.count)"
        Task { @MainActor in
            self.appendLog(line)
        }
    }
}
