import Foundation

/// MemorySentry 配置。
///
/// 三条独立监控线 + 一条 opt-in 归因线：
/// - **App 整体字节阈值**（`appFootprintThreshold`）：业务自定的硬红线。
/// - **内存压力分级告警**（`memoryPressureConfig`）：按设备总内存自适应分档，warning / critical 双级。
/// - **MetricKit 兜底**：通过门面 `enableMetricKitIntegration()` 开启。
/// - **增量归因线**（`growthDeltaThreshold`，opt-in）：相邻两拍涨幅超阈值时上报，附带嫌疑模块（时间相关性）。
///
/// 前两条与增量归因线共用 `appPollingInterval` 驱动；`appFootprintThreshold` 与百分比压力告警正交，可同时启用。
public struct MemorySentryConfiguration: Sendable {

    /// App 整体内存（phys_footprint）字节阈值。超过即上报 `didExceedAppFootprint`。
    /// 设为 `.max` 表示禁用此线（仅靠百分比压力告警）。
    public var appFootprintThreshold: UInt64

    /// 整体内存轮询间隔（秒）。`nil` 关闭轮询（字节阈值与压力告警都不再触发）。
    public var appPollingInterval: TimeInterval?

    /// 超字节阈值时是否同时采集全进程内存现场快照（`MemorySnapshot`）。
    /// 快照遍历全部 VM region，单次约几毫秒，仅在边沿触发时执行，开销可接受。
    public var capturesSnapshotOnThreshold: Bool

    /// 快照中单块区域超过此字节数即收入大区域明细（`MemorySnapshot.largeRegions`）。
    public var largeRegionThreshold: UInt64

    /// 内存压力分级告警配置。默认按设备总内存自适应分档。
    public var memoryPressureConfig: MemoryPressureConfig

    /// 是否已启用 MetricKit 兜底线。默认关闭，由门面 `enableMetricKitIntegration()` 置位。
    public var metricKitEnabled: Bool

    /// 【增量归因线，opt-in】相邻两拍 footprint 涨幅超过此字节数即上报 `didDetectMemoryGrowth`。
    /// `nil` = 关闭增量归因线（默认）。设为非 `nil` 即激活该线；不接入则行为与零侵入路径完全一致。
    public var growthDeltaThreshold: UInt64?

    /// 【增量归因线】启动宽限窗口（秒）。`startMonitoring()` 起计。
    /// 窗口内：仍逐拍更新滑动 baseline，但不产出归因上报——排除系统 / 业务集中初始化的内存爬升。默认 5s。
    public var startupGracePeriod: TimeInterval

    public init(
        appFootprintThreshold: UInt64 = 500 * 1024 * 1024,
        appPollingInterval: TimeInterval? = 1.0,
        capturesSnapshotOnThreshold: Bool = true,
        largeRegionThreshold: UInt64 = 10 * 1024 * 1024,
        memoryPressureConfig: MemoryPressureConfig = .adaptive(),
        metricKitEnabled: Bool = false,
        growthDeltaThreshold: UInt64? = nil,
        startupGracePeriod: TimeInterval = 5.0
    ) {
        self.appFootprintThreshold = appFootprintThreshold
        self.appPollingInterval = appPollingInterval
        self.capturesSnapshotOnThreshold = capturesSnapshotOnThreshold
        self.largeRegionThreshold = largeRegionThreshold
        self.memoryPressureConfig = memoryPressureConfig
        self.metricKitEnabled = metricKitEnabled
        self.growthDeltaThreshold = growthDeltaThreshold
        self.startupGracePeriod = startupGracePeriod
    }

    /// 默认配置：500MB 字节红线、1s 轮询、压力告警按设备自适应、超阈值采集快照。
    public static var `default`: MemorySentryConfiguration {
        MemorySentryConfiguration()
    }
}

/// 内存压力级别。`allCases` 顺序按"先 critical 后 warning"上报，确保严重事件先到 observer。
public enum MemoryPressureLevel: String, Sendable, CaseIterable {
    /// 警戒：内存占用偏高，建议清理可丢弃缓存、避免新增大对象。
    case warning
    /// 危险：临近系统 Jetsam 阈值，必须立即释放可释放资源以降低被强杀风险。
    case critical

    /// 同时上报多级时按此顺序遍历：critical 先于 warning。
    public static var allCases: [MemoryPressureLevel] { [.critical, .warning] }
}

/// 内存压力分级告警配置。
///
/// 占用率 = 当前 phys_footprint / 进程内存上限（task_vm_info 推算，拿不到时回退到 ProcessInfo.physicalMemory）。
/// 占用率跨越 `warningRatio` / `criticalRatio` 即触发对应级别事件。门面对每个级别独立做边沿迟滞，
/// 占用率回落至阈值以下时复位状态，避免抖动反复告警。
public struct MemoryPressureConfig: Sendable {

    /// warning 触发占用率（0–1）。建议小于 `criticalRatio`。
    public var warningRatio: Double

    /// critical 触发占用率（0–1）。
    public var criticalRatio: Double

    public init(warningRatio: Double, criticalRatio: Double) {
        self.warningRatio = warningRatio
        self.criticalRatio = criticalRatio
    }

    /// 取指定级别的触发占用率。
    public func threshold(for level: MemoryPressureLevel) -> Double {
        switch level {
        case .warning: return warningRatio
        case .critical: return criticalRatio
        }
    }

    /// 设备自适应分档默认配置：内存越小，阈值越低、越早告警。
    ///
    /// - 数值依据 iOS Jetsam 的经验观察——小内存设备（<2GB）距离系统强杀阈值更窄，
    ///   提早告警留给业务清理缓存的时间更充裕。
    /// - 调用时若不传 `physicalMemory`，按 `ProcessInfo.processInfo.physicalMemory` 取设备总内存自动分档。
    ///
    /// | 设备总内存 | warning | critical |
    /// |---|---|---|
    /// | < 2 GB | 0.55 | 0.75 |
    /// | < 4 GB | 0.65 | 0.80 |
    /// | < 6 GB | 0.70 | 0.85 |
    /// | ≥ 6 GB | 0.75 | 0.88 |
    public static func adaptive(physicalMemory: UInt64? = nil) -> MemoryPressureConfig {
        let total = physicalMemory ?? UInt64(ProcessInfo.processInfo.physicalMemory)
        let gb: UInt64 = 1024 * 1024 * 1024
        switch total {
        case ..<(2 * gb):
            return MemoryPressureConfig(warningRatio: 0.55, criticalRatio: 0.75)
        case ..<(4 * gb):
            return MemoryPressureConfig(warningRatio: 0.65, criticalRatio: 0.80)
        case ..<(6 * gb):
            return MemoryPressureConfig(warningRatio: 0.70, criticalRatio: 0.85)
        default:
            return MemoryPressureConfig(warningRatio: 0.75, criticalRatio: 0.88)
        }
    }
}
