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
            memoryPressureConfig: .adaptive(),
            growthDeltaThreshold: 30 * 1024 * 1024,     // demo 增量归因线：相邻两拍涨幅 > 30MB 即上报
            startupGracePeriod: 3.0                     // demo 启动窗口 3s（避免冷启动爬升误报）
        )
        MemorySentry.shared.update(configuration: cfg)
        // 上报时注入额外信息：当前存活模块数 + 上报类型。
        MemorySentry.shared.setGrowthContextProvider { ctx in
            ["screen": "demo", "live": "\(ctx.liveModules.count)", "kind": ctx.kind.rawValue]
        }
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
