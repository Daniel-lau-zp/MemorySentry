# MemorySentry

> 零侵入的全局内存监视器（**iOS-only**）—— App 整体字节阈值告警 · 内存压力分级告警 · 现场快照取证 · MetricKit 兜底。

![platform](https://img.shields.io/badge/platform-iOS%2015%2B-lightgrey)
![swift](https://img.shields.io/badge/swift-5.9-orange)
![spm](https://img.shields.io/badge/SPM-supported-green)
![cocoapods](https://img.shields.io/badge/CocoaPods-supported-green)
![version](https://img.shields.io/badge/version-1.0.0-blue)

## 设计理念

**零侵入**：业务代码一行不改，挂 observer + `startMonitoring()` 就能拿到全部告警事件。
不再要求业务在分配大对象时登记字节数 / 类型——那种登记方式接入成本高、容易遗漏，且只能覆盖业务自己分配的对象，对 Lottie / 第三方 SDK / 系统解码这些"业务侧拿不到"的内存反而无能为力。

三条监控线，全部从进程级数据（`phys_footprint` / VM region / MetricKit）观察，覆盖范围比登记式更全：

1. **App 整体字节阈值告警** —— 定时轮询 `phys_footprint`（与 Jetsam 口径一致），跨越业务自定字节红线即上报，并自动采集全进程内存现场快照（按 VM tag 归类、单块大区域归因推测）。
2. **内存压力分级告警** —— 同一轮询里按设备总内存的百分比双级触发（warning / critical），分档自适应。
3. **MetricKit 兜底** —— 订阅系统次日交付的 OOM / 内存峰值诊断，兜常驻轮询采不到的进程消亡盲区。

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

## 自定义观察者

```swift
final class MyObserver: MemorySentryObserver {
    func memorySentry(didExceedAppFootprint event: AppFootprintEvent) { }
    func memorySentry(didCrossMemoryPressure event: MemoryPressureEvent) { }
    func memorySentry(didReceiveMetricKitPayload event: MetricKitEvent) { }
}
```

三个回调全部有默认空实现，按需覆盖即可。开箱即用的 `ConsoleMemorySentryObserver` 已覆盖全部回调（含排查建议文案）。

> 🧵 回调在监视内部的串行队列触发，不保证主线程；observer 若要操作 UI 需自行切回主线程。

## 能力边界

| 场景 | 字节阈值告警 | 压力告警 | 现场快照 | MetricKit |
|------|:-----------:|:-------:|:-------:|:---------:|
| 自有 UIImage / Data | ✅ 计入 footprint | ✅ | ✅ 图像/堆 tag | ✅ |
| Lottie / 第三方 SDK 内部位图 | ✅ 计入 footprint | ✅ | ✅ 图像 tag | ✅ |
| 网络下载缓冲 | ✅ | ✅ | ⚠️ 取决于采样时机 | ✅ |
| App 被后台 OOM 强杀 | ❌ 进程已亡 | ❌ | ❌ | ✅（次日） |

**本模块不做**：
- 不定位"具体哪个对象 / 调用栈造成的内存增长"——那需要 Instruments（Allocations / Leaks）或 MetricKit。
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
| `MemorySentryConfiguration` | 字节阈值 / 轮询间隔 / 快照开关 / 压力配置 / MetricKit 标记 |
| `MemoryPressureConfig` / `.adaptive(physicalMemory:)` | warning / critical 比例；按设备总内存自动分档 |
| `MemoryPressureLevel` | `.warning` / `.critical`；`allCases` 上报顺序 critical 先 |
| `MemoryPressureEvent` | level / footprint / limit / ratio / threshold |
| `AppFootprintEvent` | footprint / threshold / snapshot |
| `MetricKitEvent` | eventType（.oom / .memoryWarning） / peakMemoryUsage / callStack / 时段 |
| `MemorySentryObserver` | 事件观察者协议（3 回调，全默认空实现） |
| `ConsoleMemorySentryObserver` | 开箱即用的 os.log observer |
| `MemorySnapshot` | `correlations()` / `diagnosticSummary()` / `regionGroups` / `largeRegions` |

## 目录结构

```
Sources/MemorySentry/
├── Core/
│   ├── MemorySentry.swift                # 监视中心主类（门面装配三条线）
│   ├── MemorySentryConfiguration.swift   # 配置 + 内存压力分档
│   └── MemoryEvent.swift                 # 3 类事件：footprint / pressure / metricKit
├── Observer/
│   ├── MemorySentryObserver.swift        # 观察者协议（3 回调，默认空实现）
│   └── ConsoleMemorySentryObserver.swift # os.log observer
├── Reporter/
│   ├── MemoryFootprint.swift             # phys_footprint + 进程级上限读取
│   └── MemorySnapshot.swift              # 全进程内存现场快照
└── MetricKitIntegration/
    └── MetricKitCollector.swift          # MetricKit 兜底线
```

## 测试

```bash
xcodebuild -scheme MemorySentry \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

覆盖：footprint 读取、快照采集与大区域捕获、归因推测置信度、内存压力分级告警自适应分档 / 边沿迟滞 / 双级独立触发、字节阈值边沿触发、MetricKit 订阅幂等、observer 默认空实现。
