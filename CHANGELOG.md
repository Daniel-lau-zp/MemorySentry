# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.0] - 2026-06-26

### 新增

- **增量归因线（opt-in 可选叠加层）**——对零侵入的补充，不接入则行为与 1.0.0 完全一致、零开销。
  - `enterModule(_:metadata:)` / `leaveModule(_:)`：模块起始/销毁打标记，任意线程低开销调用（注册表独立锁，不与轮询主锁争用）。
  - 轮询里以**滑动上一拍 baseline** 计算相邻两拍涨幅，超过 `growthDeltaThreshold` 即上报 `didDetectMemoryGrowth`。
  - **嫌疑模块**：涨幅区间内新注册且仍未释放的模块（时间相关性线索，**非因果证明**）。
  - **启动宽限窗口** `startupGracePeriod`（默认 5s）：窗口内逐拍更新 baseline 但不上报，排除冷启动期系统/业务集中初始化的内存爬升。
  - **无嫌疑也上报**：区间内无新增模块时 `kind = .unattributedGrowth`、嫌疑为空，仍带出当前存活模块全集（`liveModules` 与 `suspectedModules` 为两个独立字段）。
  - **双通道额外信息**：注册时 `metadata`（静态）+ 上报时 `setGrowthContextProvider`（动态，入参含存活/嫌疑模块与上报类型，锁外调用）。
- 新增类型：`MemoryGrowthEvent`、`GrowthReportKind`、`GrowthContext`、`GrowthContextProvider`、`RegisteredModule`、`ModuleRegistry`。
- `MemorySentryObserver` 新增第 4 回调 `memorySentry(didDetectMemoryGrowth:)`（默认空实现，旧接入方无需改动）。
- `MemorySentryConfiguration` 新增 `growthDeltaThreshold: UInt64?`（默认 nil）、`startupGracePeriod: TimeInterval`（默认 5）。
- `ConsoleMemorySentryObserver` 覆盖新回调；Demo 新增「增量归因线」演示 Section。

### 兼容性

- 源码与二进制层面向后兼容：配置 init 新增参数均带默认值；observer 新回调有默认空实现。未设置 `growthDeltaThreshold`、未调用 `enterModule`、未设 `contextProvider` 时增量归因线整体短路，行为与 1.0.0 一致。

## [1.0.0]

- 重构：移除所有需要业务登记的 API（`track(bytes:)` / `@MemoryTracked` / `trackLifetime` / 单次申请超限 / 泄漏检测线），统一收敛到零侵入路径。
- 三条监控线：App 整体字节阈值告警（含现场快照取证）、内存压力分级告警（设备自适应分档）、MetricKit 兜底。
