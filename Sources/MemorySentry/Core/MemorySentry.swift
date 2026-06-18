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
        restartPollingIfNeeded()
    }

    /// 停止整体内存轮询。
    public func stopMonitoring() {
        lock.lock(); defer { lock.unlock() }
        pollingTimer?.cancel()
        pollingTimer = nil
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

        let observerList = (shouldFireAppEvent || !pressureFires.isEmpty) ? observersSnapshotLocked() : []
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
