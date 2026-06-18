import XCTest
@testable import MemorySentry

/// 内存压力分级告警测试：
/// 1. 自适应分档随设备总内存的预期切换
/// 2. 阈值映射与配置可读
/// 3. 真实链路：把 warning 阈值压到 0 触发一次告警，验证 observer 收到 warning 事件
/// 4. 边沿迟滞：阈值 0 仅在首次轮询触发一次，不重复告警
final class MemoryPressureTests: XCTestCase {

    // MARK: - 自适应分档

    func testAdaptiveBucketsByTotalMemory() {
        let gb: UInt64 = 1024 * 1024 * 1024
        let tiny = MemoryPressureConfig.adaptive(physicalMemory: 1 * gb)
        XCTAssertEqual(tiny.warningRatio, 0.55, accuracy: 0.0001)
        XCTAssertEqual(tiny.criticalRatio, 0.75, accuracy: 0.0001)

        let small = MemoryPressureConfig.adaptive(physicalMemory: 3 * gb)
        XCTAssertEqual(small.warningRatio, 0.65, accuracy: 0.0001)
        XCTAssertEqual(small.criticalRatio, 0.80, accuracy: 0.0001)

        let mid = MemoryPressureConfig.adaptive(physicalMemory: 5 * gb)
        XCTAssertEqual(mid.warningRatio, 0.70, accuracy: 0.0001)
        XCTAssertEqual(mid.criticalRatio, 0.85, accuracy: 0.0001)

        let big = MemoryPressureConfig.adaptive(physicalMemory: 8 * gb)
        XCTAssertEqual(big.warningRatio, 0.75, accuracy: 0.0001)
        XCTAssertEqual(big.criticalRatio, 0.88, accuracy: 0.0001)
    }

    // MARK: - 阈值映射

    func testThresholdLookup() {
        let cfg = MemoryPressureConfig(warningRatio: 0.6, criticalRatio: 0.85)
        XCTAssertEqual(cfg.threshold(for: .warning), 0.6)
        XCTAssertEqual(cfg.threshold(for: .critical), 0.85)
    }

    func testAllCasesOrderingPrioritizesCritical() {
        // 同时跨越多级时，critical 先于 warning 上报。
        XCTAssertEqual(MemoryPressureLevel.allCases, [.critical, .warning])
    }

    // MARK: - 真实链路：把 warning 压到 0 强制触发一次

    /// 收集压力告警事件的 spy。
    private final class PressureSpy: MemorySentryObserver, @unchecked Sendable {
        let lock = NSLock()
        private var _events: [MemoryPressureEvent] = []
        var events: [MemoryPressureEvent] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
        func memorySentry(didCrossMemoryPressure event: MemoryPressureEvent) {
            lock.lock(); _events.append(event); lock.unlock()
        }
    }

    func testWarningFiresWhenThresholdIsZero() {
        // warning=0 / critical=2（不可达），强制只触发 warning。
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: .max,         // 不让字节阈值线干扰
            appPollingInterval: 0.2,             // 200ms 轮询
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 0, criticalRatio: 2)
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = PressureSpy()
        sentry.add(spy)
        sentry.startMonitoring()

        // 给至少 2 个轮询周期:首次触发 + 再轮询一拍验证不重复。
        let exp = XCTestExpectation(description: "warning event observed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            if spy.events.contains(where: { $0.level == .warning }) {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 3.0)
        sentry.stopMonitoring()

        let warnings = spy.events.filter { $0.level == .warning }
        XCTAssertEqual(warnings.count, 1, "warning 应只触发一次（边沿迟滞）")
        let critical = spy.events.filter { $0.level == .critical }
        XCTAssertTrue(critical.isEmpty, "critical 阈值不可达不应触发")

        if let w = warnings.first {
            XCTAssertGreaterThan(w.footprint, 0)
            XCTAssertGreaterThan(w.limit, 0)
            XCTAssertEqual(w.threshold, 0, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(w.ratio, 0)
        }
    }

    // MARK: - 双级独立触发

    func testCriticalAndWarningBothFireWhenBothCrossed() {
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: .max,
            appPollingInterval: 0.2,
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 0, criticalRatio: 0)
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = PressureSpy()
        sentry.add(spy)
        sentry.startMonitoring()

        let exp = XCTestExpectation(description: "both levels observed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            let lvls = Set(spy.events.map { $0.level })
            if lvls.contains(.warning) && lvls.contains(.critical) {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 3.0)
        sentry.stopMonitoring()

        let critical = spy.events.filter { $0.level == .critical }
        let warning = spy.events.filter { $0.level == .warning }
        XCTAssertEqual(critical.count, 1)
        XCTAssertEqual(warning.count, 1)

        // 上报顺序 critical 先于 warning（同一拍轮询里）。
        if let firstCritical = spy.events.firstIndex(where: { $0.level == .critical }),
           let firstWarning = spy.events.firstIndex(where: { $0.level == .warning }) {
            XCTAssertLessThan(firstCritical, firstWarning)
        }
    }

    // MARK: - update 重置迟滞

    func testUpdateConfigResetsHysteresis() {
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: .max,
            appPollingInterval: 0.2,
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 0, criticalRatio: 2)
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = PressureSpy()
        sentry.add(spy)
        sentry.startMonitoring()

        let firstFire = XCTestExpectation(description: "first warning")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            if spy.events.contains(where: { $0.level == .warning }) {
                firstFire.fulfill()
            }
        }
        wait(for: [firstFire], timeout: 3.0)

        // 通过 update 同样配置触发迟滞复位 → 第二次仍能再上报一次
        var newCfg = sentry.configuration
        newCfg.memoryPressureConfig = MemoryPressureConfig(warningRatio: 0, criticalRatio: 2)
        sentry.update(configuration: newCfg)

        let secondFire = XCTestExpectation(description: "second warning after update")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            let count = spy.events.filter { $0.level == .warning }.count
            if count >= 2 { secondFire.fulfill() }
        }
        wait(for: [secondFire], timeout: 3.0)
        sentry.stopMonitoring()
    }
}
