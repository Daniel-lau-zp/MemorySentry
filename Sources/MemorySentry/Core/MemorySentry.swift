import Foundation
import MetricKit
import os.log

/// 全局内存监视器（iOS-only）。
///
/// 三条监控线，零侵入登记——挂上 observer、`startMonitoring()` 即可：
/// 1. **App 整体超字节阈值** —— 定时轮询 `phys_footprint`（与 Jetsam 口径一致），跨越业务自定字节红线即上报。
/// 2. **内存压力分级告警** —— 同一轮询里按设备总内存的百分比双级触发（warning / critical），分档自适应。
/// 3. **MetricKit 兜底** —— 订阅系统次日 OOM / 内存峰值诊断（`enableMetricKitIntegration`）。
///
/// 线程安全（`@unchecked Sendable` + 内部锁）。可挂多个 observer，回调统一在内部串行队列触发。
public final class MemorySentry: @unchecked Sendable {
    public static let shared = MemorySentry()

    public private(set) var configuration: MemorySentryConfiguration

    private let lock = NSLock()
    private var observers: [WeakObserverBox] = []

    private let callbackQueue: DispatchQueue
    private var pollingTimer: DispatchSourceTimer?
    /// 字节阈值线的边沿状态：true 表示当前已超阈值，下次降回才会复位。
    private var lastAppEventFired = false
    /// 内存压力告警状态：warning / critical 各自独立的边沿迟滞标志。
    private var pressureFired: [MemoryPressureLevel: Bool] = [:]

    /// MetricKit 兜底线采集器。`enableMetricKitIntegration` 时懒装配。
    private var metricKitCollector: MetricKitCollector?

    /// 模块注册表（opt-in 增量归因线）。独立锁，enter/leave 低开销。
    private let moduleRegistry = ModuleRegistry()
    /// 上报前补充额外信息的闭包。受 `lock` 保护。
    private var growthContextProvider: GrowthContextProvider?
    /// 是否调用过 `enterModule`。一旦置位不回退——用于激活判据，避免 enter 后 leave 表空被误判未激活。受 `lock` 保护。
    private var hasEverRegisteredModule = false
    /// 上一拍 footprint（滑动 baseline）。受 `lock` 保护。
    private var lastFootprint: UInt64?
    /// 上一拍轮询时刻（嫌疑区间下界）。受 `lock` 保护。
    private var lastPollTimestamp: Date?
    /// `startMonitoring()` 时刻（启动宽限窗口起点）。受 `lock` 保护。
    private var monitoringStartedAt: Date?

    private let log = OSLog(subsystem: "com.memorysentry", category: "MemorySentry")

    public init(
        configuration: MemorySentryConfiguration = .default,
        callbackQueue: DispatchQueue = DispatchQueue(label: "com.memorysentry.callback")
    ) {
        self.configuration = configuration
        self.callbackQueue = callbackQueue
    }

    deinit {
        pollingTimer?.cancel()
    }

    /// 更新配置。会按新的整体轮询间隔重建定时器，并清除上一拍迟滞标志。
    public func update(configuration: MemorySentryConfiguration) {
        lock.lock()
        self.configuration = configuration
        // 阈值变更后清除上一拍迟滞，让下一轮轮询按新阈值重新判定边沿。
        lastAppEventFired = false
        pressureFired.removeAll()
        // 等价重启增量归因线的滑动状态，避免跨配置变更算出脏增量。
        resetGrowthStateLocked()
        lock.unlock()

        restartPollingIfNeeded()
    }

    public func add(_ observer: MemorySentryObserver) {
        lock.lock(); defer { lock.unlock() }
        observers.append(WeakObserverBox(observer))
    }

    public func remove(_ observer: MemorySentryObserver) {
        lock.lock(); defer { lock.unlock() }
        observers.removeAll { $0.value === observer || $0.value == nil }
    }

    /// 启动整体内存轮询。重复调用会重建定时器。
    public func startMonitoring() {
        lock.lock()
        // 启动宽限窗口起点 + 复位滑动 baseline：窗口内只更新 baseline 不上报，排除启动期爬升。
        monitoringStartedAt = Date()
        lastFootprint = nil
        lastPollTimestamp = nil
        lock.unlock()
        restartPollingIfNeeded()
    }

    /// 停止整体内存轮询。
    public func stopMonitoring() {
        lock.lock(); defer { lock.unlock() }
        pollingTimer?.cancel()
        pollingTimer = nil
        resetGrowthStateLocked()
    }

    // MARK: - 增量归因线（opt-in 模块注册）
    /// 标记一个模块进入存活状态。任意线程可调，低开销。同名覆盖（刷新时间戳 + metadata）。
    ///
    /// 这是对零侵入的 opt-in 叠加层；不调用则行为与现状完全一致。
    public func enterModule(_ name: String, metadata: [String: String] = [:]) {
        moduleRegistry.enter(name, metadata: metadata, at: Date())
        lock.lock(); hasEverRegisteredModule = true; lock.unlock()
    }

    /// 标记一个模块离开（视为已释放）。任意线程可调，幂等。
    public func leaveModule(_ name: String) {
        moduleRegistry.leave(name)
    }

    /// 设置增量归因上报的额外信息提供闭包。传 `nil` 清除。
    ///
    /// 闭包在上报的串行回调队列上、分发 observer 之前调用（此时不持有任何内部锁）。须快速返回、勿阻塞。
    public func setGrowthContextProvider(_ provider: GrowthContextProvider?) {
        lock.lock(); growthContextProvider = provider; lock.unlock()
    }

    /// 复位增量归因线的滑动状态。已持有 `lock` 时调用。
    private func resetGrowthStateLocked() {
        lastFootprint = nil
        lastPollTimestamp = nil
        monitoringStartedAt = nil
    }

    /// 立即采集一次全进程内存现场快照。可在任意时机手动取证。
    /// - Parameter largeRegionThreshold: 单块区域超过此字节数即收入明细，默认 10MB。
    public func captureSnapshot(largeRegionThreshold: UInt64 = 10 * 1024 * 1024) -> MemorySnapshot {
        MemorySnapshot.capture(largeRegionThreshold: largeRegionThreshold)
    }

    // MARK: -
    /// 启用 MetricKit 兜底线：订阅系统次日交付的诊断 / 指标负载（OOM、内存峰值）。
    @discardableResult
    public func enableMetricKitIntegration() -> MetricKitAvailability {
        lock.lock()
        let collector: MetricKitCollector
        if let existing = metricKitCollector {
            collector = existing
        } else {
            collector = MetricKitCollector { [weak self] event in
                self?.dispatchToObservers { $0.memorySentry(didReceiveMetricKitPayload: event) }
            }
            metricKitCollector = collector
        }
        configuration.metricKitEnabled = true
        lock.unlock()

        collector.enable()
        return .available
    }

    /// 关闭 MetricKit 兜底线：解除系统订阅。幂等。
    ///
    /// 关闭后采集器对象本身仍被门面持久持有（与 `MemorySentry.shared` 同生命周期），仅解除系统订阅、
    /// 不释放；再次 `enableMetricKitIntegration()` 复用同一实例。
    public func disableMetricKitIntegration() {
        lock.lock()
        let collector = metricKitCollector
        configuration.metricKitEnabled = false
        lock.unlock()

        collector?.disable()
    }

    // MARK: -
    private func restartPollingIfNeeded() {
        lock.lock()
        pollingTimer?.cancel()
        pollingTimer = nil
        guard let interval = configuration.appPollingInterval, interval > 0 else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.checkAppFootprint()
        }
        pollingTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func checkAppFootprint() {
        guard let reading = MemoryFootprint.read() else { return }
        let footprint = reading.footprint
        let now = Date()

        lock.lock()
        let threshold = configuration.appFootprintThreshold
        let exceeded = footprint > threshold
        let shouldFireAppEvent = exceeded && !lastAppEventFired
        lastAppEventFired = exceeded
        let capturesSnapshot = configuration.capturesSnapshotOnThreshold
        let largeRegionThreshold = configuration.largeRegionThreshold

        // 内存压力按进程内存上限的百分比判定，与字节阈值正交。
        // 进程级上限优先用 task_vm_info.limit_bytes_remaining + footprint（与 Jetsam 口径一致）；
        // 拿不到时回退到 ProcessInfo.physicalMemory（设备总物理内存）。
        let pressureLimit = reading.processLimit ?? UInt64(ProcessInfo.processInfo.physicalMemory)
        let pressureCfg = configuration.memoryPressureConfig
        let pressureFires = evaluatePressureLocked(
            footprint: footprint,
            limit: pressureLimit,
            config: pressureCfg
        )

        // 增量归因线（opt-in，短路保护）：未激活时整段不进入，零开销零行为变化。
        let growthPlan = evaluateGrowthLocked(footprint: footprint, now: now)

        let needObservers = shouldFireAppEvent || !pressureFires.isEmpty || growthPlan != nil
        let observerList = needObservers ? observersSnapshotLocked() : []
        lock.unlock()

        // 快照在锁外采集：region 遍历较重，不阻塞外部调用。
        if shouldFireAppEvent {
            let snapshot = capturesSnapshot
                ? MemorySnapshot.capture(largeRegionThreshold: largeRegionThreshold)
                : nil
            let event = AppFootprintEvent(
                footprint: footprint,
                threshold: threshold,
                snapshot: snapshot
            )
            for ob in observerList { ob.memorySentry(didExceedAppFootprint: event) }
        }

        for fire in pressureFires {
            let event = MemoryPressureEvent(
                level: fire.level,
                footprint: footprint,
                limit: pressureLimit,
                ratio: Double(footprint) / Double(pressureLimit),
                threshold: fire.threshold
            )
            for ob in observerList { ob.memorySentry(didCrossMemoryPressure: event) }
        }

        // 增量归因上报：registry 快照 / contextProvider 都在锁外，避免与接入方闭包构成死锁。
        if let plan = growthPlan {
            let live = moduleRegistry.liveSnapshot()
            // 嫌疑 = 区间内新增且仍存活：半开区间 lower < registeredAt <= upper，避免与上一拍重复归因。
            let suspected = live.filter { plan.lowerBound < $0.registeredAt && $0.registeredAt <= plan.upperBound }
            let kind: GrowthReportKind = suspected.isEmpty ? .unattributedGrowth : .suspectedModuleGrowth
            let context = GrowthContext(
                kind: kind,
                liveModules: live,
                suspectedModules: suspected,
                footprint: plan.footprint,
                delta: plan.delta
            )
            let extra = plan.provider?(context) ?? [:]
            let event = MemoryGrowthEvent(
                kind: kind,
                footprint: plan.footprint,
                delta: plan.delta,
                deltaThreshold: plan.deltaThreshold,
                liveModules: live,
                suspectedModules: suspected,
                context: extra
            )
            for ob in observerList { ob.memorySentry(didDetectMemoryGrowth: event) }
        }
    }

    /// 锁内决策传到锁外执行的载体（与 `pressureFires` 同模式）。仅在确定要上报时非 nil。
    private struct GrowthPlan {
        let delta: UInt64
        let deltaThreshold: UInt64
        let lowerBound: Date
        let upperBound: Date
        let footprint: UInt64
        let provider: GrowthContextProvider?
    }

    /// 评估增量归因线。已持有 `lock` 时调用。
    ///
    /// - 未激活（无阈值 / 无 provider / 从未注册模块）→ 整段短路，返回 nil。
    /// - 激活时**无条件滑动 baseline**（`lastFootprint` / `lastPollTimestamp` 每拍更新，含启动窗口内）：
    ///   启动期陡升被逐拍切分，窗口结束首个有效拍的增量只是"相邻一拍差"，不含整段启动累积涨幅。
    /// - 仅当有上一拍、阈值已配置、涨幅为正、且已过启动窗口、增量超阈值时，返回 `GrowthPlan` 触发上报。
    private func evaluateGrowthLocked(footprint: UInt64, now: Date) -> GrowthPlan? {
        let active = configuration.growthDeltaThreshold != nil
            || growthContextProvider != nil
            || hasEverRegisteredModule
        guard active else { return nil }

        let prevFootprint = lastFootprint
        let prevPollTs = lastPollTimestamp
        let startedAt = monitoringStartedAt
        let provider = growthContextProvider

        // (A) 无条件滑动 baseline —— 窗口内也更新，这是消化启动涨幅的关键。
        lastFootprint = footprint
        lastPollTimestamp = now

        // (B) 首拍无上一拍、未配阈值、或非增长 → 只填 baseline 不上报。
        guard let prev = prevFootprint,
              let deltaThreshold = configuration.growthDeltaThreshold,
              footprint > prev else { return nil }
        let delta = footprint - prev

        // (C) 启动宽限窗口内：只滑动 baseline，不上报。
        if let startedAt, now.timeIntervalSince(startedAt) < configuration.startupGracePeriod {
            return nil
        }
        guard delta > deltaThreshold else { return nil }

        // (D) 嫌疑区间下界 = 上一拍轮询时刻；首个判定拍 prevPollTs 可能为 nil，用 startedAt 兜底。
        let lower = prevPollTs ?? startedAt ?? now
        return GrowthPlan(
            delta: delta,
            deltaThreshold: deltaThreshold,
            lowerBound: lower,
            upperBound: now,
            footprint: footprint,
            provider: provider
        )
    }

    /// 评估当前 footprint / limit 是否跨越压力阈值。
    ///
    /// 双向迟滞：相同 level 在「未触发 → 触发」时上报，footprint 回落至阈值以下时复位，避免抖动反复告警。
    /// 已持有 `lock` 时调用。返回需上报的级别清单（按 critical 优先）。
    private func evaluatePressureLocked(
        footprint: UInt64,
        limit: UInt64,
        config: MemoryPressureConfig
    ) -> [(level: MemoryPressureLevel, threshold: Double)] {
        guard limit > 0 else { return [] }
        let ratio = Double(footprint) / Double(limit)
        var fires: [(MemoryPressureLevel, Double)] = []
        for level in MemoryPressureLevel.allCases {
            let thr = config.threshold(for: level)
            let crossed = ratio >= thr
            let prev = pressureFired[level] ?? false
            if crossed && !prev {
                fires.append((level, thr))
            }
            pressureFired[level] = crossed
        }
        return fires
    }

    private func observersSnapshotLocked() -> [MemorySentryObserver] {
        observers = observers.filter { $0.value != nil }
        return observers.compactMap { $0.value }
    }

    /// 把事件分发到全部 observer：取快照后在 `callbackQueue` 上逐个回调。
    private func dispatchToObservers(_ deliver: @escaping (MemorySentryObserver) -> Void) {
        lock.lock()
        let snapshot = observersSnapshotLocked()
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        callbackQueue.async {
            for ob in snapshot { deliver(ob) }
        }
    }

    private final class WeakObserverBox {
        weak var value: MemorySentryObserver?
        init(_ v: MemorySentryObserver) { self.value = v }
    }
}
