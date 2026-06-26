import SwiftUI
import MemorySentry

/// MemorySentry 接入演示。
///
/// 演示要点：
/// 1. 实时显示 footprint / 进程上限 / 占用率（每 0.5s 刷新一次）
/// 2. 分配 / 释放大块内存按钮，主动制造跨阈值场景，触发 observer 回调
/// 3. 字节阈值告警附带的现场快照摘要
/// 4. 手动 `captureSnapshot()` 取证按钮
struct ContentView: View {
    @StateObject private var bridge = EventBridge.shared
    @StateObject private var pulse = MemoryPulse()
    @State private var allocatedMB: Int = 0
    @State private var manualSnapshot: String?
    @State private var blocks: [Data] = []
    @State private var moduleEntered = false

    var body: some View {
        NavigationView {
            Form {
                Section("实时读数（0.5s 刷新）") {
                    row("footprint", value: "\(format(pulse.footprint))MB")
                    row("进程上限", value: "\(format(pulse.limit))MB")
                    HStack {
                        Text("占用率")
                        Spacer()
                        Text("\(String(format: "%.1f", pulse.ratio * 100))%")
                            .foregroundColor(pulse.ratio >= 0.85 ? .red : (pulse.ratio >= 0.7 ? .orange : .primary))
                    }
                    row("已主动分配", value: "\(allocatedMB)MB")
                }

                Section("主动制造内存压力") {
                    Button("分配 50MB") { allocate(megabytes: 50) }
                    Button("分配 100MB") { allocate(megabytes: 100) }
                    Button(role: .destructive) {
                        blocks.removeAll()
                        allocatedMB = 0
                    } label: {
                        Text("释放全部")
                    }
                    Text("默认配置：footprintThreshold=200MB，跨过即触发；压力告警走设备自适应分档。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("增量归因线（opt-in 模块注册）") {
                    Button(moduleEntered ? "leaveModule(\"ImageCache\")" : "enterModule(\"ImageCache\")") {
                        if moduleEntered {
                            MemorySentry.shared.leaveModule("ImageCache")
                        } else {
                            MemorySentry.shared.enterModule("ImageCache", metadata: ["v": "2.1"])
                        }
                        moduleEntered.toggle()
                    }
                    Button("注册模块后分配 50MB（制造嫌疑）") {
                        MemorySentry.shared.enterModule("ImageCache", metadata: ["v": "2.1"])
                        moduleEntered = true
                        allocate(megabytes: 50)
                    }
                    Text("当前模块：\(moduleEntered ? "ImageCache（已注册）" : "无")。注册后涨幅 > 30MB → suspectedModuleGrowth（嫌疑含 ImageCache）；不注册直接涨 → unattributedGrowth。启动 3s 内只更新 baseline 不报。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("手动取证") {
                    Button("captureSnapshot()") {
                        manualSnapshot = MemorySentry.shared.captureSnapshot().diagnosticSummary()
                    }
                    if let manualSnapshot {
                        Text(manualSnapshot)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section("事件日志（observer 回调）") {
                    if bridge.log.isEmpty {
                        Text("尚无事件 — 试试上方「分配 100MB」按钮越过 200MB 红线。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(bridge.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                if let snapshot = bridge.lastSnapshot {
                    Section("最近一次告警附带的现场快照") {
                        Text(snapshot)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("MemorySentry Demo")
        }
        .navigationViewStyle(.stack)
    }

    /// 分配指定 MB 数的内存，写入 0xAB 触发实际驻留（避免被系统延迟分配抹掉）。
    private func allocate(megabytes: Int) {
        let bytes = megabytes * 1024 * 1024
        var buf = Data(count: bytes)
        buf.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress {
                memset(base, 0xAB, bytes)
            }
        }
        blocks.append(buf)
        allocatedMB += megabytes
    }

    private func format(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1024 / 1024)
    }

    @ViewBuilder
    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

/// 0.5s 轮询读取 footprint，驱动 UI 实时刷新。
@MainActor
final class MemoryPulse: ObservableObject {
    @Published var footprint: UInt64 = 0
    @Published var limit: UInt64 = 0
    @Published var ratio: Double = 0

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        guard let r = MemoryFootprint.read() else { return }
        footprint = r.footprint
        limit = r.processLimit ?? UInt64(ProcessInfo.processInfo.physicalMemory)
        ratio = limit > 0 ? Double(footprint) / Double(limit) : 0
    }
}
