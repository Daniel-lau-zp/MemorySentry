import Foundation
import os.log

/// 把告警事件打到统一日志（os.log）的开箱即用 observer。生产可直接挂上做兜底排查。
public final class ConsoleMemorySentryObserver: MemorySentryObserver, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.memorysentry", category: "alert")

    public init() {}

    public func memorySentry(didExceedAppFootprint event: AppFootprintEvent) {
        logger.error("""
        [MemorySentry] App 整体内存超阈值 footprint=\(Self.mb(event.footprint), privacy: .public)MB \
        threshold=\(Self.mb(event.threshold), privacy: .public)MB
        """)
        if let snapshot = event.snapshot {
            logger.error("\(snapshot.diagnosticSummary(), privacy: .public)")
        }
    }

    public func memorySentry(didCrossMemoryPressure event: MemoryPressureEvent) {
        let ratioText = String(format: "%.1f", event.ratio * 100)
        let thresholdText = String(format: "%.1f", event.threshold * 100)
        switch event.level {
        case .warning:
            logger.warning("""
            [MemorySentry] 内存压力 warning footprint=\(Self.mb(event.footprint), privacy: .public)MB / \
            limit=\(Self.mb(event.limit), privacy: .public)MB \
            ratio=\(ratioText, privacy: .public)% threshold=\(thresholdText, privacy: .public)% \
            建议：清理可丢弃缓存 / 暂停后台任务 / 释放大图。
            """)
        case .critical:
            logger.fault("""
            [MemorySentry] 内存压力 critical footprint=\(Self.mb(event.footprint), privacy: .public)MB / \
            limit=\(Self.mb(event.limit), privacy: .public)MB \
            ratio=\(ratioText, privacy: .public)% threshold=\(thresholdText, privacy: .public)% \
            建议：立即释放可释放资源，临近 Jetsam 阈值有被强杀风险。
            """)
        }
    }

    public func memorySentry(didReceiveMetricKitPayload event: MetricKitEvent) {
        switch event.eventType {
        case .oom:
            logger.fault("""
            [MemorySentry] MetricKit 上报疑似 OOM 强杀（次日交付） \
            callStackFrames=\(event.callStack.count, privacy: .public) \
            建议：结合堆栈定位崩溃前的大内存分配路径，核对峰值内存与缓存策略。
            """)
        case .memoryWarning:
            let peak = event.peakMemoryUsage.map { Self.mb($0) } ?? "-"
            logger.error("""
            [MemorySentry] MetricKit 上报内存峰值 peak=\(peak, privacy: .public)MB \
            建议：关注峰值时段的大对象分配，评估是否逼近系统 Jetsam 阈值。
            """)
        }
    }

    private static func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1024 / 1024)
    }
}
