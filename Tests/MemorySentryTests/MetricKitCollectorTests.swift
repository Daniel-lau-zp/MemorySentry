import XCTest
@testable import MemorySentry

/// MetricKit 兜底线测试：聚焦门面调用幂等性与事件结构体可构造，不依赖系统真机事件。
final class MetricKitCollectorTests: XCTestCase {

    func testEnableIntegrationDoesNotCrash() {
        let sentry = MemorySentry(
            configuration: MemorySentryConfiguration(appPollingInterval: nil)
        )
        let availability = sentry.enableMetricKitIntegration()
        guard case .available = availability else {
            return XCTFail("iOS 应返回 .available")
        }

        sentry.disableMetricKitIntegration()
        sentry.disableMetricKitIntegration()
    }

    func testEnableIntegrationIsIdempotent() {
        let sentry = MemorySentry(
            configuration: MemorySentryConfiguration(appPollingInterval: nil)
        )
        let first = sentry.enableMetricKitIntegration()
        let second = sentry.enableMetricKitIntegration()
        XCTAssertEqual(availabilityLabel(first), availabilityLabel(second))
    }

    private func availabilityLabel(_ value: MetricKitAvailability) -> String {
        switch value {
        case .available: return "available"
        }
    }

    func testMetricKitConfigFlagTracksEnable() {
        let sentry = MemorySentry(
            configuration: MemorySentryConfiguration(appPollingInterval: nil)
        )
        XCTAssertFalse(sentry.configuration.metricKitEnabled)
        sentry.enableMetricKitIntegration()
        XCTAssertTrue(sentry.configuration.metricKitEnabled)
    }

    func testMetricKitEventConstructs() {
        let begin = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 60)
        let oom = MetricKitEvent(
            eventType: .oom,
            peakMemoryUsage: nil,
            callStack: ["0x1000 in MyApp", "0x2000 in UIKit"],
            timeStampBegin: begin,
            timeStampEnd: end
        )
        XCTAssertEqual(oom.eventType, .oom)
        XCTAssertNil(oom.peakMemoryUsage)
        XCTAssertEqual(oom.callStack.count, 2)

        let warning = MetricKitEvent(
            eventType: .memoryWarning,
            peakMemoryUsage: 512 * 1024 * 1024,
            callStack: [],
            timeStampBegin: begin,
            timeStampEnd: end
        )
        XCTAssertEqual(warning.eventType, .memoryWarning)
        XCTAssertEqual(warning.peakMemoryUsage, 512 * 1024 * 1024)
    }
}
