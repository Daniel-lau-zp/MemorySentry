import XCTest
@testable import MemorySentry

/// 增量归因线（opt-in 模块注册）测试。
///
/// 用极短 startupGracePeriod + 极小 growthDeltaThreshold + 主动分配内存触发涨幅，
/// 覆盖：默认短路 / 启动窗口抑制 / 嫌疑归因 / 无嫌疑也报 / leave 不入嫌疑 /
/// 滑动 baseline 不累计 / contextProvider 透传 / 默认空实现 / update 复位。
final class MemoryGrowthAttributionTests: XCTestCase {

    /// 收集增量归因事件的 spy。
    private final class GrowthSpy: MemorySentryObserver, @unchecked Sendable {
        let lock = NSLock()
        private var _events: [MemoryGrowthEvent] = []
        var events: [MemoryGrowthEvent] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
        func memorySentry(didDetectMemoryGrowth event: MemoryGrowthEvent) {
            lock.lock(); _events.append(event); lock.unlock()
        }
    }

    /// 持有大块内存的容器：用 deinit 之外的显式释放控制生命周期，制造可控涨幅。
    private final class Ballast {
        private var blocks: [Data] = []
        /// 追加约 mb 兆字节并写入（强制 page 落地，计入 footprint）。
        func grow(mb: Int) {
            var d = Data(count: mb * 1024 * 1024)
            d.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { memset(base, 0xAB, raw.count) }
            }
            blocks.append(d)
        }
        func release() { blocks.removeAll() }
    }

    // MARK: -
    /// 默认配置（无阈值 / 无 enter / 无 provider）下制造涨幅，应零事件——验证零侵入短路。
    func testGrowthLineInactiveByDefault() {
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: .max,
            appPollingInterval: 0.2,
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 1.5, criticalRatio: 2)
            // growthDeltaThreshold 默认 nil
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = GrowthSpy()
        sentry.add(spy)
        sentry.startMonitoring()

        let ballast = Ballast()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { ballast.grow(mb: 30) }

        let settle = XCTestExpectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { settle.fulfill() }
        wait(for: [settle], timeout: 3.0)
        sentry.stopMonitoring()

        XCTAssertTrue(spy.events.isEmpty, "未激活时不应产出任何增量事件")
        ballast.release()
    }

    // MARK: -
    /// 启动窗口内的涨幅不上报；窗口过后的涨幅才上报。
    func testStartupWindowSuppressesReport() {
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: .max,
            appPollingInterval: 0.2,
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 1.5, criticalRatio: 2),
            growthDeltaThreshold: 5 * 1024 * 1024,   // 5MB 增量阈值
            startupGracePeriod: 1.0                   // 1s 启动窗口
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = GrowthSpy()
        sentry.add(spy)
        sentry.startMonitoring()

        let ballast = Ballast()
        // 窗口内（0.4s）制造大涨幅 —— 应被抑制。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { ballast.grow(mb: 30) }

        let inWindow = XCTestExpectation(description: "still in window")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.9) { inWindow.fulfill() }
        wait(for: [inWindow], timeout: 2.0)
        XCTAssertTrue(spy.events.isEmpty, "启动窗口内的涨幅不应上报")

        // 窗口过后（>1s）再制造一拍涨幅 —— 应上报。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { ballast.grow(mb: 30) }
        let afterWindow = XCTestExpectation(description: "after window report")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            if !spy.events.isEmpty { afterWindow.fulfill() }
        }
        wait(for: [afterWindow], timeout: 3.0)
        sentry.stopMonitoring()

        XCTAssertFalse(spy.events.isEmpty, "启动窗口过后的涨幅应上报")
        ballast.release()
    }

    // MARK: -
    /// enter 模块后涨幅超阈 → suspectedModuleGrowth，嫌疑含该模块且 metadata 透传。
    func testSuspectedModuleAttribution() {
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: .max,
            appPollingInterval: 0.2,
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 1.5, criticalRatio: 2),
            growthDeltaThreshold: 5 * 1024 * 1024,
            startupGracePeriod: 0.1
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = GrowthSpy()
        sentry.add(spy)
        sentry.startMonitoring()

        let ballast = Ballast()
        // 过启动窗口后，先 enter 模块，再在下一拍区间内分配 → 嫌疑应命中。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            sentry.enterModule("ImageCache", metadata: ["v": "1"])
            ballast.grow(mb: 30)
        }

        let exp = XCTestExpectation(description: "suspected growth")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) {
            if spy.events.contains(where: { $0.kind == .suspectedModuleGrowth }) { exp.fulfill() }
        }
        wait(for: [exp], timeout: 3.0)
        sentry.stopMonitoring()

        guard let event = spy.events.first(where: { $0.kind == .suspectedModuleGrowth }) else {
            return XCTFail("应产出 suspectedModuleGrowth 事件")
        }
        XCTAssertTrue(event.suspectedModules.contains { $0.name == "ImageCache" })
        XCTAssertEqual(event.suspectedModules.first { $0.name == "ImageCache" }?.metadata["v"], "1")
        XCTAssertGreaterThan(event.delta, 5 * 1024 * 1024)
        ballast.release()
    }

    // MARK: -
    /// 无任何模块但涨幅超阈 → unattributedGrowth，嫌疑与存活均为空，仍上报。
    func testUnattributedGrowthStillReports() {
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: .max,
            appPollingInterval: 0.2,
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 1.5, criticalRatio: 2),
            growthDeltaThreshold: 5 * 1024 * 1024,
            startupGracePeriod: 0.1
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = GrowthSpy()
        sentry.add(spy)
        sentry.startMonitoring()

        let ballast = Ballast()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { ballast.grow(mb: 30) }

        let exp = XCTestExpectation(description: "unattributed growth")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) {
            if spy.events.contains(where: { $0.kind == .unattributedGrowth }) { exp.fulfill() }
        }
        wait(for: [exp], timeout: 3.0)
        sentry.stopMonitoring()

        guard let event = spy.events.first(where: { $0.kind == .unattributedGrowth }) else {
            return XCTFail("无模块但超阈应产出 unattributedGrowth 事件")
        }
        XCTAssertTrue(event.suspectedModules.isEmpty)
        XCTAssertTrue(event.liveModules.isEmpty)
        XCTAssertGreaterThan(event.delta, 5 * 1024 * 1024)
        ballast.release()
    }

    // MARK: -
    /// enter 后立刻 leave 的模块，不出现在嫌疑也不在存活。
    func testLeftModuleNotSuspected() {
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: .max,
            appPollingInterval: 0.2,
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 1.5, criticalRatio: 2),
            growthDeltaThreshold: 5 * 1024 * 1024,
            startupGracePeriod: 0.1
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = GrowthSpy()
        sentry.add(spy)
        sentry.startMonitoring()

        let ballast = Ballast()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            sentry.enterModule("Temp")
            sentry.leaveModule("Temp")
            ballast.grow(mb: 30)
        }

        let exp = XCTestExpectation(description: "growth without left module")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) {
            if !spy.events.isEmpty { exp.fulfill() }
        }
        wait(for: [exp], timeout: 3.0)
        sentry.stopMonitoring()

        for event in spy.events {
            XCTAssertFalse(event.suspectedModules.contains { $0.name == "Temp" }, "已 leave 的模块不应入嫌疑")
            XCTAssertFalse(event.liveModules.contains { $0.name == "Temp" }, "已 leave 的模块不应在存活")
        }
        ballast.release()
    }

    // MARK: -
    /// contextProvider 返回值透传到事件 context，且入参与事件一致。
    func testContextProviderInjection() {
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: .max,
            appPollingInterval: 0.2,
            capturesSnapshotOnThreshold: false,
            memoryPressureConfig: MemoryPressureConfig(warningRatio: 1.5, criticalRatio: 2),
            growthDeltaThreshold: 5 * 1024 * 1024,
            startupGracePeriod: 0.1
        )
        let sentry = MemorySentry(configuration: cfg)
        let spy = GrowthSpy()
        sentry.add(spy)
        sentry.setGrowthContextProvider { ctx in
            ["build": "42", "kind": ctx.kind.rawValue, "live": "\(ctx.liveModules.count)"]
        }
        sentry.startMonitoring()

        let ballast = Ballast()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            sentry.enterModule("Net")
            ballast.grow(mb: 30)
        }

        let exp = XCTestExpectation(description: "context injected")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) {
            if spy.events.contains(where: { $0.context["build"] == "42" }) { exp.fulfill() }
        }
        wait(for: [exp], timeout: 3.0)
        sentry.stopMonitoring()

        guard let event = spy.events.first(where: { !$0.context.isEmpty }) else {
            return XCTFail("应有携带 context 的事件")
        }
        XCTAssertEqual(event.context["build"], "42")
        XCTAssertEqual(event.context["kind"], event.kind.rawValue)
        XCTAssertEqual(event.context["live"], "\(event.liveModules.count)")
        ballast.release()
    }

    // MARK: -
    /// 默认空实现可直接调用，不崩溃。
    func testDefaultEmptyImplementationCallable() {
        final class Bare: MemorySentryObserver, @unchecked Sendable {}
        let bare: MemorySentryObserver = Bare()
        bare.memorySentry(didDetectMemoryGrowth: MemoryGrowthEvent(
            kind: .unattributedGrowth, footprint: 1, delta: 1, deltaThreshold: 1,
            liveModules: [], suspectedModules: [], context: [:]
        ))
    }

    // MARK: -
    /// Console observer 处理新回调不崩溃。
    func testConsoleObserverHandlesGrowthCallback() {
        let console = ConsoleMemorySentryObserver()
        let now = Date()
        console.memorySentry(didDetectMemoryGrowth: MemoryGrowthEvent(
            kind: .suspectedModuleGrowth, footprint: 200 * 1024 * 1024, delta: 30 * 1024 * 1024,
            deltaThreshold: 5 * 1024 * 1024,
            liveModules: [RegisteredModule(name: "ImageCache", registeredAt: now, metadata: ["v": "1"])],
            suspectedModules: [RegisteredModule(name: "ImageCache", registeredAt: now, metadata: ["v": "1"])],
            context: ["build": "42"]
        ))
        console.memorySentry(didDetectMemoryGrowth: MemoryGrowthEvent(
            kind: .unattributedGrowth, footprint: 200 * 1024 * 1024, delta: 30 * 1024 * 1024,
            deltaThreshold: 5 * 1024 * 1024, liveModules: [], suspectedModules: [], context: [:]
        ))
    }
}
