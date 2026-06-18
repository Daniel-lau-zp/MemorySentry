import SwiftUI
import MemorySentry

@main
struct MemorySentryDemoApp: App {
    init() {
        // 演示阈值压低到设备级风险告警可触发的范围。
        // 真实 App 使用默认 .adaptive() 即可。
        let cfg = MemorySentryConfiguration(
            appFootprintThreshold: 200 * 1024 * 1024,  // demo 字节红线 200MB
            appPollingInterval: 0.5,                    // demo 加快轮询
            capturesSnapshotOnThreshold: true,
            memoryPressureConfig: .adaptive()
        )
        MemorySentry.shared.update(configuration: cfg)
        MemorySentry.shared.add(ConsoleMemorySentryObserver())
        MemorySentry.shared.add(EventBridge.shared)
        MemorySentry.shared.startMonitoring()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
