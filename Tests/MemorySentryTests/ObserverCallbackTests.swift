import XCTest
@testable import MemorySentry

/// Observer 协议测试：默认空实现可直接调用 / 真实链路触发字节阈值事件 / Console observer 不崩溃。
final class ObserverCallbackTests: XCTestCase {

    /// 收集 footprint 字节阈值事件的 spy。
    private final class FootprintSpy: MemorySentryObserver, @unchecked Sendable {
        let lock = NSLock()
        let exceeded = XCTestExpectation(description: "footprint exceeded")
        private var _events: [AppFootprintEvent] = []
        var events: [AppFootprintEvent] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
        func memorySentry(didExceedAppFootprint event: AppFootprintEvent) {
            lock.lock(); _events.append(event); lock.unlock()
            exceeded.fulfill()
        }
    }

    // MARK: -
    func testFootprintThresholdFiresOnceOnEdge() {
        // 阈值压到 0：当前 footprint 必然 > 0，应触发；继续轮询不应重复触发（边沿迟滞）。
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: 0,
            appPollingInterval: 0.2,
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 1.5, criticalRatio: 2) // 不让压力线干扰
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = FootprintSpy()
        sentry.add(spy)
        sentry.startMonitoring()

        wait(for: [spy.exceeded], timeout: 2.0)

        // 再多等几拍验证不重复
        let settle = XCTestExpectation(description: "no duplicate")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            settle.fulfill()
        }
        wait(for: [settle], timeout: 2.0)
        sentry.stopMonitoring()

        XCTAssertEqual(spy.events.count, 1, "字节阈值事件应只触发一次（边沿迟滞）")
        XCTAssertEqual(spy.events.first?.threshold, 0)
        XCTAssertGreaterThan(spy.events.first?.footprint ?? 0, 0)
    }

    // MARK: -
    func testDefaultEmptyImplementationsAreCallable() {
        final class Bare: MemorySentryObserver, @unchecked Sendable {}
        let bare: MemorySentryObserver = Bare()
        let now = Date()
        bare.memorySentry(didExceedAppFootprint: AppFootprintEvent(footprint: 1, threshold: 1, snapshot: nil))
        bare.memorySentry(didCrossMemoryPressure: MemoryPressureEvent(level: .warning, footprint: 1, limit: 2, ratio: 0.5, threshold: 0.5))
        bare.memorySentry(didReceiveMetricKitPayload: MetricKitEvent(eventType: .memoryWarning, peakMemoryUsage: 0, callStack: [], timeStampBegin: now, timeStampEnd: now))
    }

    // MARK: -
    func testConsoleObserverHandlesAllCallbacks() {
        let console = ConsoleMemorySentryObserver()
        let now = Date()
        console.memorySentry(didExceedAppFootprint: AppFootprintEvent(footprint: 600 * 1024 * 1024, threshold: 500 * 1024 * 1024, snapshot: nil))
        console.memorySentry(didCrossMemoryPressure: MemoryPressureEvent(
            level: .critical, footprint: 800 * 1024 * 1024, limit: 1024 * 1024 * 1024,
            ratio: 0.78, threshold: 0.75
        ))
        console.memorySentry(didReceiveMetricKitPayload: MetricKitEvent(
            eventType: .oom, peakMemoryUsage: nil, callStack: ["0x1 in App"],
            timeStampBegin: now, timeStampEnd: now
        ))
    }
}
