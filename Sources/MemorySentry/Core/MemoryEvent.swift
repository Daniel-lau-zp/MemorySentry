import Foundation

/// App 整体内存超字节阈值事件。
///
/// 由整体监控线在轮询里产出：phys_footprint 跨越 `MemorySentryConfiguration.appFootprintThreshold`
/// 即触发一次。边沿触发——降回阈值后复位，再次超过才会复发。
public struct AppFootprintEvent: Sendable {
    /// 当前 phys_footprint（字节）。
    public let footprint: UInt64
    /// 配置的整体阈值（字节）。
    public let threshold: UInt64
    /// 超阈值那一刻的全进程内存现场快照。`nil` 表示未开启快照采集。
    public let snapshot: MemorySnapshot?

    public init(
        footprint: UInt64,
        threshold: UInt64,
        snapshot: MemorySnapshot? = nil
    ) {
        self.footprint = footprint
        self.threshold = threshold
        self.snapshot = snapshot
    }
}

/// 内存压力分级告警事件。
///
/// 由内存压力线在轮询里按设备自适应阈值产出：占用率（footprint / processLimit）跨越 warning / critical
/// 阈值即触发，每个级别独立做边沿迟滞，占用率回落至阈值以下后复位、再次跨越才会复发。
public struct MemoryPressureEvent: Sendable {
    /// 触发的告警级别。
    public let level: MemoryPressureLevel
    /// 当前 phys_footprint（字节）。
    public let footprint: UInt64
    /// 进程内存上限（字节）。优先取 task_vm_info 推算的进程上限，拿不到时回退到设备总物理内存。
    public let limit: UInt64
    /// 当前占用率 = footprint / limit。
    public let ratio: Double
    /// 触发该级别所用的占用率阈值。
    public let threshold: Double

    public init(level: MemoryPressureLevel, footprint: UInt64, limit: UInt64, ratio: Double, threshold: Double) {
        self.level = level
        self.footprint = footprint
        self.limit = limit
        self.ratio = ratio
        self.threshold = threshold
    }
}

/// MetricKit 兜底诊断事件。
///
/// 由 MetricKit 兜底线在收到系统诊断 / 指标负载后产出，封装 OOM 崩溃或内存峰值信息。
public struct MetricKitEvent: Sendable {
    /// 事件类型。
    public enum EventType: String, Sendable {
        /// 系统因内存压力强杀（OOM / Jetsam）的崩溃诊断。
        case oom
        /// 内存峰值指标负载（非崩溃）。
        case memoryWarning
    }

    /// 事件类型。
    public let eventType: EventType
    /// 内存峰值（字节），来自 `memoryMetrics?.peakMemoryUsage`；无数据时为 `nil`。
    public let peakMemoryUsage: UInt64?
    /// 堆栈元信息数组，每条形如 `"0x… in ModuleName"`；解析失败为空数组。
    public let callStack: [String]
    /// 负载覆盖时段的起始时刻。
    public let timeStampBegin: Date
    /// 负载覆盖时段的结束时刻。
    public let timeStampEnd: Date

    public init(
        eventType: EventType,
        peakMemoryUsage: UInt64?,
        callStack: [String],
        timeStampBegin: Date,
        timeStampEnd: Date
    ) {
        self.eventType = eventType
        self.peakMemoryUsage = peakMemoryUsage
        self.callStack = callStack
        self.timeStampBegin = timeStampBegin
        self.timeStampEnd = timeStampEnd
    }
}
