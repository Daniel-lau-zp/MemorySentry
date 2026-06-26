import Foundation

/// 增量归因上报类型。区分启动期之后的两种情形。
public enum GrowthReportKind: String, Sendable {
    /// 涨幅超阈值，且区间内有新增模块 → 这些模块被标为嫌疑。
    case suspectedModuleGrowth
    /// 涨幅超阈值，但区间内无新增模块 → 仍上报，嫌疑为空。
    case unattributedGrowth
}

/// `setGrowthContextProvider` 闭包的入参。上报前在锁外构造并回调接入方。
public struct GrowthContext: Sendable {
    /// 本次上报类型。
    public let kind: GrowthReportKind
    /// 当前存活（已注册未释放）模块全集。
    public let liveModules: [RegisteredModule]
    /// 本次涨幅区间内新增且当前仍存活的嫌疑模块子集（`unattributedGrowth` 时为空）。
    public let suspectedModules: [RegisteredModule]
    /// 本拍 phys_footprint（字节）。
    public let footprint: UInt64
    /// 相对上一拍的增量（字节）。
    public let delta: UInt64

    public init(
        kind: GrowthReportKind,
        liveModules: [RegisteredModule],
        suspectedModules: [RegisteredModule],
        footprint: UInt64,
        delta: UInt64
    ) {
        self.kind = kind
        self.liveModules = liveModules
        self.suspectedModules = suspectedModules
        self.footprint = footprint
        self.delta = delta
    }
}

/// 接入方补充额外信息的闭包。入参为 `GrowthContext`，返回任意键值补充信息。
///
/// 在归因上报的串行回调队列上、分发 observer 之前调用（此时不持有任何内部锁）。须快速返回、勿阻塞。
public typealias GrowthContextProvider = @Sendable (GrowthContext) -> [String: String]

/// 增量归因事件（opt-in 增量归因线产出）。
///
/// 语义：本拍 footprint 相对上一拍涨幅超过 `MemorySentryConfiguration.growthDeltaThreshold`，
/// 且已过启动宽限窗口。携带相关性线索——**嫌疑模块仅表示"该涨幅区间内新注册且未释放"的时间相关性，
/// 不证明因果**；具体定位仍需 Instruments。
public struct MemoryGrowthEvent: Sendable {
    /// 本次上报类型（有嫌疑 / 无归因）。
    public let kind: GrowthReportKind
    /// 本拍 phys_footprint（字节）。
    public let footprint: UInt64
    /// 相对上一拍的增量（字节，正值；本线只在涨幅为正且超阈值时产出）。
    public let delta: UInt64
    /// 触发用的增量阈值（字节）。
    public let deltaThreshold: UInt64
    /// 当前存活模块全集（名 + 注册时间 + metadata）。
    public let liveModules: [RegisteredModule]
    /// 嫌疑模块子集（区间内新增且未释放；`unattributedGrowth` 时为空）。`suspectedModules ⊆ liveModules`。
    public let suspectedModules: [RegisteredModule]
    /// `contextProvider` 返回的接入方补充信息；未设置 provider 时为空字典。
    public let context: [String: String]

    public init(
        kind: GrowthReportKind,
        footprint: UInt64,
        delta: UInt64,
        deltaThreshold: UInt64,
        liveModules: [RegisteredModule],
        suspectedModules: [RegisteredModule],
        context: [String: String]
    ) {
        self.kind = kind
        self.footprint = footprint
        self.delta = delta
        self.deltaThreshold = deltaThreshold
        self.liveModules = liveModules
        self.suspectedModules = suspectedModules
        self.context = context
    }
}
