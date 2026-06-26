# MemorySentryDemo

MemorySentry 的可执行接入演示（SwiftUI App）。

## 演示要点

- 实时显示当前 `phys_footprint` / 进程上限 / 占用率（每 0.5s 刷新一次）
- 一键分配 50MB / 100MB Data，主动制造跨阈值场景，触发：
  - 字节阈值告警（`didExceedAppFootprint`，默认 200MB）
  - 内存压力分级告警（`didCrossMemoryPressure`，warning / critical）
  - 字节阈值告警附带的全进程现场快照（`MemorySnapshot.diagnosticSummary`）
- 手动 `captureSnapshot()` 取证按钮
- **增量归因线（opt-in）**：`enterModule` / `leaveModule` 打标记 + 「注册模块后分配 50MB」按钮，触发 `didDetectMemoryGrowth`——区分 `suspectedModuleGrowth`（嫌疑含 ImageCache）与 `unattributedGrowth`（无新增模块），启动 3s 窗口内不上报
- 事件日志面板（observer 回调实时展示，最近 30 条）

## 运行

工程由 [xcodegen](https://github.com/yonaskolb/XcodeGen) 管理（仅 `project.yml` + `Sources/` 入库，`.xcodeproj` 由本机生成）：

```sh
brew install xcodegen          # 未装则先装
cd Example/MemorySentryDemo
xcodegen generate              # 生成 MemorySentryDemo.xcodeproj
open MemorySentryDemo.xcodeproj
# Xcode 选 iPhone 模拟器，cmd+R 运行
```

`project.yml` 用本地 path 引用上级库包（`packages: MemorySentry: { path: ../.. }`），改库源码后 Xcode 会重编，可直接在 Demo 里调试库本身。
