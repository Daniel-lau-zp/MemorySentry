# MemorySentry

> 零侵入的全局内存监视器（**iOS-only**）—— App 整体字节阈值告警 · 内存压力分级告警 · 现场快照取证 · MetricKit 兜底 · 模块增量归因（opt-in）。

![platform](https://img.shields.io/badge/platform-iOS%2015%2B-lightgrey)
![swift](https://img.shields.io/badge/swift-5.9-orange)
![spm](https://img.shields.io/badge/SPM-supported-green)
![cocoapods](https://img.shields.io/badge/CocoaPods-supported-green)
![version](https://img.shields.io/badge/version-1.1.0-blue)

## 设计理念

**零侵入**：业务代码一行不改，挂 observer + `startMonitoring()` 就能拿到全部告警事件。
不再要求业务在分配大对象时登记字节数 / 类型——那种登记方式接入成本高、容易遗漏，且只能覆盖业务自己分配的对象，对 Lottie / 第三方 SDK / 系统解码这些"业务侧拿不到"的内存反而无能为力。

三条监控线，全部从进程级数据（`phys_footprint` / VM region / MetricKit）观察，覆盖范围比登记式更全：

1. **App 整体字节阈值告警** —— 定时轮询 `phys_footprint`（与 Jetsam 口径一致），跨越业务自定字节红线即上报，并自动采集全进程内存现场快照（按 VM tag 归类、单块大区域归因推测）。
2. **内存压力分级告警** —— 同一轮询里按设备总内存的百分比双级触发（warning / critical），分档自适应。
3. **MetricKit 兜底** —— 订阅系统次日交付的 OOM / 内存峰值诊断，兜常驻轮询采不到的进程消亡盲区。

> ℹ️ **1.1.0**：新增 opt-in 增量归因线（模块注册 + 相邻两拍涨幅归因），作为零侵入的可选叠加层——不接入则行为与 1.0.0 完全一致。详见下文「增量归因线」与 [CHANGELOG](CHANGELOG.md)。
>
> ℹ️ 1.0.0 是一次重构：移除了所有需要业务登记的 API（`track(bytes:)` / `@MemoryTracked` / `trackLifetime` / 单次申请超限 / 泄漏检测线），统一收敛到零侵入路径。如需对象级泄漏定位，请使用 Instruments（Allocations / Leaks）或 FBRetainCycleDetector。

---

## 安装

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/liuzeping/MemorySentry.git", from: "1.0.0")
]
```

或本地路径引用：

```swift
.package(path: "../MemorySentry")
```

### CocoaPods

```ruby
pod 'MemorySentry', '~> 1.0.0'
```

## 快速开始

```swift
import MemorySentry

// 1. 配置（不传也可以，默认 500MB 字节红线 + 1s 轮询 + 自适应压力告警）
let config = MemorySentryConfiguration(
    appFootprintThreshold: 500 * 1024 * 1024,   // 业务自定红线
    appPollingInterval: 1.0,                    // 1s 轮询
    capturesSnapshotOnThreshold: true           // 跨字节红线时自动采集快照
    // memoryPressureConfig 默认 .adaptive() 按设备总内存分档
)
MemorySentry.shared.update(configuration: config)

// 2. 挂观察者
MemorySentry.shared.add(ConsoleMemorySentryObserver())   // 开箱即用，打 os.log
MemorySentry.shared.add(myAlertObserver)                  // 自定义告警

// 3. 启动监控（重复调用会重建定时器，无副作用）
MemorySentry.shared.startMonitoring()

// 4.（可选）启用 MetricKit 兜底，订阅系统次日诊断
MemorySentry.shared.enableMetricKitIntegration()
```

## 监控线详解

### 1. App 整体字节阈值告警

业务自定的硬红线，与百分比压力告警正交。`phys_footprint` 跨越 `appFootprintThreshold` 即上报一次（边沿触发——降回阈值后复位才会再次告警）。

```swift
final class MyObserver: MemorySentryObserver {
    func memorySentry(didExceedAppFootprint event: AppFootprintEvent) {
        // event.footprint / event.threshold
        if let snapshot = event.snapshot {
            print(snapshot.diagnosticSummary())
        }
    }
}
```

设 `appFootprintThreshold = .max` 可单独禁用此线。

### 2. 内存压力分级告警

判定口径：占用率 = `phys_footprint / 进程内存上限`。
- 进程上限优先取 `task_vm_info.limit_bytes_remaining + footprint` —— 与系统 Jetsam 判定口径一致。
- 拿不到（部分模拟器 / 旧 iOS）则回退到 `ProcessInfo.processInfo.physicalMemory`（设备总物理内存）。

阈值按设备总内存自适应分档（`MemoryPressureConfig.adaptive()`），**设备内存越小，触发阈值越低**：

| 设备总内存 | warning | critical |
|---|---|---|
| < 2 GB | 55% | 75% |
| < 4 GB | 65% | 80% |
| < 6 GB | 70% | 85% |
| ≥ 6 GB | 75% | 88% |

依据：iOS Jetsam 阈值在小内存设备上更近，提早告警留给业务清缓存的时间更充裕。

```swift
// 默认即可：MemorySentryConfiguration 默认带 .adaptive()
// 也可显式指定：
var cfg = MemorySentry.shared.configuration
cfg.memoryPressureConfig = MemoryPressureConfig(warningRatio: 0.6, criticalRatio: 0.85)
MemorySentry.shared.update(configuration: cfg)

// observer 接收事件
func memorySentry(didCrossMemoryPressure event: MemoryPressureEvent) {
    switch event.level {
    case .warning:  // 清理可丢弃缓存 / 暂停后台预加载
        break
    case .critical: // 立即释放可释放资源；临近 Jetsam 强杀阈值
        break
    }
    // event.footprint / .limit / .ratio / .threshold
}
```

**判定行为约束**：
- 双向迟滞：每个级别独立做"未触发→触发"边沿，占用率回落至阈值以下后复位，再次跨越才会复发。
- 同一拍同时跨越多级时按 `MemoryPressureLevel.allCases` 顺序上报：**critical 先于 warning**。
- `update(configuration:)` 会清除上一拍迟滞标志，让新阈值在下一轮轮询里重新评估边沿。

### 3. 现场快照取证：MemorySnapshot

跨字节红线时自动采集（`capturesSnapshotOnThreshold` 默认开），通过 `vm_region_recurse_64` 遍历全部 VM region 按 VM tag 聚合。**这条路覆盖业务侧拿不到的分配**：Lottie 解码的图片、系统 ImageIO 解码的位图等都会落到对应 VM tag（CoreGraphics / ImageIO / IOKit）里被统计到。

```swift
// 任意时机手动取证
let snapshot = MemorySentry.shared.captureSnapshot()
print(snapshot.diagnosticSummary())
// footprint / resident / virtual / compressed 全景
// imageLikeBytes（图像类合计）/ heapBytes（堆合计）
// regionGroups：按字节降序的 Top 区域
// largeRegions：单块超阈值的大区域明细（含地址）
```

`largeRegions` 挑出**单块 size 超过阈值**（默认 10MB）的区域，保留字节数、VM tag 与起始地址。`correlations()` 给每块大区域归类到 `RegionKind`：

| `RegionKind` | confidence | 含义 |
|---|---|---|
| `.image` | high | 图像 tag（CoreGraphics / ImageIO / IOKit）→ 大概率是位图（自有或第三方解码） |
| `.heap` | medium | malloc 各档 → 可能含 Data / 自定义 buffer，一块含多个对象，仅到 region 粒度 |
| `.unknown` | low | 未识别 tag，建议用 `address` 配合 `vmmap` 比对 |

> ⚠️ 一块 VM region ≠ 一个对象。大位图 / 大 Data 通常独占一块大 region 能精准对应；malloc 小堆区一块含多对象，明细给的是"该堆区总量"。

### 4. MetricKit 兜底线

常驻轮询依赖 App 在前台。App 被系统杀掉、后台 OOM 这类场景轮询采不到。MetricKit 兜的就是这块盲区——订阅系统聚合的诊断 / 指标负载（**次日交付，非实时**）。

```swift
MemorySentry.shared.enableMetricKitIntegration()    // 已订阅返回 .available（幂等）

func memorySentry(didReceiveMetricKitPayload event: MetricKitEvent) {
    switch event.eventType {
    case .oom:           // 疑似 OOM/Jetsam 强杀（EXC_RESOURCE + SIGKILL）
        print(event.callStack)
    case .memoryWarning: // 内存峰值指标
        print(event.peakMemoryUsage ?? 0)
    }
}

MemorySentry.shared.disableMetricKitIntegration()
```

**诚实标注**：
- **次日聚合交付**：兜的是事后取证，不是现场告警。
- **不保证 100% 覆盖**：用户长期不开 App / 卸载，该次报告就丢了。
- **OOM 判据保守**：仅 `EXC_RESOURCE` + `SIGKILL` 判为 OOM，宁可漏报不误报。

### 5. 增量归因线（可选叠加层 / opt-in）

> ⚠️ 这是**对零侵入的补充，而非回退**——不接入则行为与上面三条线完全一致、零开销。只有设了 `growthDeltaThreshold`、调用过 `enterModule`、或设了 `contextProvider` 才激活。

回答的问题：**「这次内存上涨，时间上是否和某个刚加载的模块相关？」** 模块在起始时 `enterModule` 打标记、销毁时 `leaveModule` 删标记；轮询里对比**相邻两拍** footprint 涨幅，超过 `growthDeltaThreshold` 即上报，并把「该涨幅区间内新注册且仍未释放的模块」标为**嫌疑**。

> ⚠️ 嫌疑模块是**时间相关性线索，不证明因果**——只说明该模块恰在涨幅区间内注册，不代表内存就是它分配的。对象级定位仍需 Instruments。

```swift
// 1. 配置：开启增量归因线
var cfg = MemorySentry.shared.configuration
cfg.growthDeltaThreshold = 30 * 1024 * 1024   // 相邻两拍涨幅 > 30MB 即上报
cfg.startupGracePeriod   = 5.0                 // 启动后 5s 内只更新 baseline 不上报
MemorySentry.shared.update(configuration: cfg)

// 2.（可选）上报时补充全局额外信息
MemorySentry.shared.setGrowthContextProvider { ctx in
    // ctx.kind / ctx.liveModules / ctx.suspectedModules / ctx.footprint / ctx.delta
    ["screen": currentScreenName, "user": userTier]
}

// 3. 在模块生命周期两端打标记（任意线程，低开销）
MemorySentry.shared.enterModule("ImageCache", metadata: ["v": "2.1"])
// ... 模块运行 ...
MemorySentry.shared.leaveModule("ImageCache")

// 4. observer 接收
func memorySentry(didDetectMemoryGrowth event: MemoryGrowthEvent) {
    switch event.kind {
    case .suspectedModuleGrowth: // 涨幅区间内有新增模块
        print(event.suspectedModules.map(\.name))
    case .unattributedGrowth:    // 涨幅超阈但无新增模块（仍上报）
        break
    }
    // event.delta / .footprint / .liveModules / .context
}
```

**判定行为约束**：
- **滑动上一拍 baseline**：`delta = 本拍 footprint − 上一拍 footprint`，每拍滑动，不是相对某个固定基准。
- **启动宽限窗口**：`startMonitoring()` 起 `startupGracePeriod` 秒内**仍逐拍更新 baseline 但不上报**——排除系统/业务集中初始化的爬升。因为 baseline 逐拍滑动，窗口结束首拍的增量只是「相邻一拍差」，不含整段启动累积涨幅。
- **无嫌疑也上报**：窗口外只要单拍涨幅超阈值就上报。区间内无新增模块时 `kind = .unattributedGrowth`、`suspectedModules` 为空，但 `liveModules`（当前存活全集）照常带出。
- **`liveModules` 与 `suspectedModules` 是两个独立字段**：前者是当前所有未释放模块，后者是其中「本次涨幅区间内新增」的子集，可为空。
- **双通道额外信息**：注册时 `metadata`（静态）+ 上报时 `contextProvider`（动态，入参含存活/嫌疑模块与上报类型）。

## 自定义观察者

```swift
final class MyObserver: MemorySentryObserver {
    func memorySentry(didExceedAppFootprint event: AppFootprintEvent) { }
    func memorySentry(didCrossMemoryPressure event: MemoryPressureEvent) { }
    func memorySentry(didReceiveMetricKitPayload event: MetricKitEvent) { }
    func memorySentry(didDetectMemoryGrowth event: MemoryGrowthEvent) { } // opt-in 增量归因线
}
```

四个回调全部有默认空实现，按需覆盖即可。开箱即用的 `ConsoleMemorySentryObserver` 已覆盖全部回调（含排查建议文案）。

> 🧵 回调在监视内部的串行队列触发，不保证主线程；observer 若要操作 UI 需自行切回主线程。

## 能力边界

| 场景 | 字节阈值告警 | 压力告警 | 现场快照 | MetricKit |
|------|:-----------:|:-------:|:-------:|:---------:|
| 自有 UIImage / Data | ✅ 计入 footprint | ✅ | ✅ 图像/堆 tag | ✅ |
| Lottie / 第三方 SDK 内部位图 | ✅ 计入 footprint | ✅ | ✅ 图像 tag | ✅ |
| 网络下载缓冲 | ✅ | ✅ | ⚠️ 取决于采样时机 | ✅ |
| App 被后台 OOM 强杀 | ❌ 进程已亡 | ❌ | ❌ | ✅（次日） |

**本模块不做**：
- 不定位"具体哪个对象 / 调用栈造成的内存增长"——那需要 Instruments（Allocations / Leaks）或 MetricKit。增量归因线只给「涨幅区间内新增模块」的**时间相关性线索**，不替代对象级定位。
- 不做对象级泄漏检测、循环引用检测——前者用 Instruments，后者用 Memory Graph / FBRetainCycleDetector。

本模块的定位是"线上常驻、低开销、零侵入、能按设备级风险给出实时分级告警，并在跨阈值时自动留证"。

## API 速查

| 类型 / 方法 | 说明 |
|------------|------|
| `MemorySentry.shared` | 全局单例监视中心 |
| `add(_:)` / `remove(_:)` | 增删 observer |
| `startMonitoring()` / `stopMonitoring()` | 启停整体内存轮询 |
| `update(configuration:)` | 更新配置；会按新轮询间隔重建定时器、清迟滞 |
| `captureSnapshot(largeRegionThreshold:)` | 手动采集内存现场快照 |
| `enableMetricKitIntegration()` / `disableMetricKitIntegration()` | 启停 MetricKit 兜底（幂等） |
| `enterModule(_:metadata:)` / `leaveModule(_:)` | 【opt-in】模块起始/销毁打标记，供增量归因线圈定嫌疑 |
| `setGrowthContextProvider(_:)` | 【opt-in】设置上报时的额外信息提供闭包（传 nil 清除） |
| `MemorySentryConfiguration` | 字节阈值 / 轮询间隔 / 快照开关 / 压力配置 / MetricKit 标记 / 增量阈值 / 启动窗口 |
| `MemoryPressureConfig` / `.adaptive(physicalMemory:)` | warning / critical 比例；按设备总内存自动分档 |
| `MemoryPressureLevel` | `.warning` / `.critical`；`allCases` 上报顺序 critical 先 |
| `MemoryPressureEvent` | level / footprint / limit / ratio / threshold |
| `AppFootprintEvent` | footprint / threshold / snapshot |
| `MetricKitEvent` | eventType（.oom / .memoryWarning） / peakMemoryUsage / callStack / 时段 |
| `MemoryGrowthEvent` | kind / footprint / delta / deltaThreshold / liveModules / suspectedModules / context |
| `GrowthReportKind` | `.suspectedModuleGrowth` / `.unattributedGrowth` |
| `GrowthContext` | contextProvider 入参：kind / liveModules / suspectedModules / footprint / delta |
| `RegisteredModule` | name / registeredAt / metadata |
| `MemorySentryObserver` | 事件观察者协议（4 回调，全默认空实现） |
| `ConsoleMemorySentryObserver` | 开箱即用的 os.log observer |
| `MemorySnapshot` | `correlations()` / `diagnosticSummary()` / `regionGroups` / `largeRegions` |

## 可执行 Demo

[Example/MemorySentryDemo](Example/MemorySentryDemo/) 是 SwiftUI 单页 Demo，覆盖库的全部核心调用面：实时 footprint / 进程上限 / 占用率读数、一键分配大块内存触发字节阈值与压力告警、字节阈值告警附带的现场快照摘要、手动 `captureSnapshot()` 取证、observer 回调日志。

运行（工程由 [xcodegen](https://github.com/yonaskolb/XcodeGen) 管理，仓库不入库 `.xcodeproj`）：

```sh
brew install xcodegen
cd Example/MemorySentryDemo
xcodegen generate
open MemorySentryDemo.xcodeproj
```

## 目录结构

```
Sources/MemorySentry/
├── Core/
│   ├── MemorySentry.swift                # 监视中心主类（门面装配各条线）
│   ├── MemorySentryConfiguration.swift   # 配置 + 内存压力分档
│   ├── MemoryEvent.swift                 # 3 类事件：footprint / pressure / metricKit
│   ├── MemoryGrowthEvent.swift           # 增量归因事件 + 上报类型 + contextProvider 类型
│   └── ModuleRegistry.swift              # opt-in 模块注册表（独立锁）
├── Observer/
│   ├── MemorySentryObserver.swift        # 观察者协议（4 回调，默认空实现）
│   └── ConsoleMemorySentryObserver.swift # os.log observer
├── Reporter/
│   ├── MemoryFootprint.swift             # phys_footprint + 进程级上限读取
│   └── MemorySnapshot.swift              # 全进程内存现场快照
└── MetricKitIntegration/
    └── MetricKitCollector.swift          # MetricKit 兜底线

Example/MemorySentryDemo/                 # 可执行 SwiftUI Demo（xcodegen 工程）
├── project.yml                           # 工程清单
├── README.md                             # demo 说明 + 运行步骤
└── Sources/                              # DemoApp / ContentView / EventBridge
```

## 测试

```bash
xcodebuild -scheme MemorySentry \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

覆盖：footprint 读取、快照采集与大区域捕获、归因推测置信度、内存压力分级告警自适应分档 / 边沿迟滞 / 双级独立触发、字节阈值边沿触发、MetricKit 订阅幂等、observer 默认空实现、增量归因线（默认短路 / 启动窗口抑制 / 嫌疑归因 / 无嫌疑也报 / leave 剔除 / contextProvider 透传）。
