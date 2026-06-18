import Foundation
import MetricKit
import os.log

/// 启用 MetricKit 兜底线的结果状态。
public enum MetricKitAvailability: Sendable {
    /// MetricKit 已成功订阅诊断负载。
    case available
}

/// MetricKit 兜底线采集器。
///
/// 订阅 `MXMetricManager`，把系统次日交付的诊断/指标负载提取为 `MetricKitEvent`：
/// - 诊断负载里筛 OOM/Jetsam 崩溃（`EXC_RESOURCE` + `SIGKILL`），转 `.oom` 事件；
/// - 指标负载里取内存峰值 `peakMemoryUsage`，转 `.memoryWarning` 事件。
/// 提取完成后经 `onPayload` 闭包回调出去，由门面负责派发到回调队列再通知 observer。
final class MetricKitCollector: NSObject {
    /// 订阅状态，幂等保护：已订阅再 enable / 未订阅再 disable 均忽略。
    private var isEnabled = false
    /// 保护 `isEnabled` 的锁。
    private let stateLock = NSLock()
    /// 堆栈树递归展开的深度上限，超过即停止下钻。
    /// 真机调用栈深度物理上有限（通常数百帧），此上限仅作防御性兜底，避免异常深树导致栈溢出。
    private static let maxFrameDepth = 512
    /// 提取完成后的事件回调，由 `MemorySentry` 门面注入，负责后续派发。
    private let onPayload: (MetricKitEvent) -> Void
    private let log = OSLog(subsystem: "com.memorysentry", category: "MetricKit")

    /// - Parameter onPayload: 每提取出一条 `MetricKitEvent` 即回调一次（在系统后台队列上触发）。
    init(onPayload: @escaping (MetricKitEvent) -> Void) {
        self.onPayload = onPayload
        super.init()
    }

    // MARK: -
    /// 订阅 `MXMetricManager`。幂等：已订阅则忽略并 os.log。
    ///
    /// `MXMetricManager.shared.add(_:)` 要求主线程调用，故此处切到主线程执行。
    func enable() {
        stateLock.lock()
        if isEnabled {
            stateLock.unlock()
            os_log("MetricKit 已订阅，忽略重复 enable", log: log, type: .info)
            return
        }
        isEnabled = true
        stateLock.unlock()

        let subscribe = { MXMetricManager.shared.add(self) }
        if Thread.isMainThread {
            subscribe()
        } else {
            DispatchQueue.main.async(execute: subscribe)
        }
    }

    /// 解除订阅。幂等：未订阅则忽略。
    func disable() {
        stateLock.lock()
        if !isEnabled {
            stateLock.unlock()
            return
        }
        isEnabled = false
        stateLock.unlock()

        let unsubscribe = { MXMetricManager.shared.remove(self) }
        if Thread.isMainThread {
            unsubscribe()
        } else {
            DispatchQueue.main.async(execute: unsubscribe)
        }
    }

    // MARK: -
    /// 把 `MXCallStackTree` 转为可读堆栈字符串数组，每条形如 `"0x… in ModuleName"`。
    /// 解析失败返回空数组，不抛异常——诊断信息缺失不应影响兜底上报。
    private func callStackFrames(from tree: MXCallStackTree) -> [String] {
        let data = tree.jsonRepresentation()
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stacks = root["callStacks"] as? [[String: Any]]
        else {
            return []
        }

        var frames: [String] = []
        // callStackTree 是树形：每条 callStack 下挂 callStackRootFrames，子帧经 subFrames 递归。
        for stack in stacks {
            guard let rootFrames = stack["callStackRootFrames"] as? [[String: Any]] else { continue }
            for frame in rootFrames {
                appendFrames(frame, into: &frames, depth: 0)
            }
        }
        return frames
    }

    /// 递归展开单个调用帧及其子帧，拼成 `"0x地址 in 模块名"` 追加到结果。
    /// `depth` 达到 `maxFrameDepth` 即停止下钻，防御异常深的堆栈树导致栈溢出。
    private func appendFrames(_ frame: [String: Any], into frames: inout [String], depth: Int) {
        guard depth < Self.maxFrameDepth else { return }
        let binary = frame["binaryName"] as? String ?? "unknown"
        if let address = frame["address"] as? UInt64 {
            frames.append(String(format: "0x%llx in %@", address, binary))
        } else {
            frames.append("0x0 in \(binary)")
        }
        if let subFrames = frame["subFrames"] as? [[String: Any]] {
            for sub in subFrames {
                appendFrames(sub, into: &frames, depth: depth + 1)
            }
        }
    }
}

// MARK: - MXMetricManagerSubscriber
extension MetricKitCollector: MXMetricManagerSubscriber {
    /// 指标负载回调（系统后台队列触发）：取内存峰值转 `.memoryWarning` 事件。
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            // 无内存指标的负载跳过，不产出空事件。
            guard let memory = payload.memoryMetrics else { continue }
            let peak = UInt64(memory.peakMemoryUsage.converted(to: .bytes).value)
            let event = MetricKitEvent(
                eventType: .memoryWarning,
                peakMemoryUsage: peak,
                callStack: [],
                timeStampBegin: payload.timeStampBegin,
                timeStampEnd: payload.timeStampEnd
            )
            onPayload(event)
        }
    }

    /// 诊断负载回调（系统后台队列触发）：筛 OOM/Jetsam 崩溃转 `.oom` 事件。
    ///
    /// OOM 的判据是系统资源异常强杀——`exceptionType == EXC_RESOURCE` 且 `signal == SIGKILL`。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            guard let crashes = payload.crashDiagnostics else { continue }
            for crash in crashes {
                guard isOOM(crash) else { continue }
                let event = MetricKitEvent(
                    eventType: .oom,
                    peakMemoryUsage: nil,
                    callStack: callStackFrames(from: crash.callStackTree),
                    timeStampBegin: payload.timeStampBegin,
                    timeStampEnd: payload.timeStampEnd
                )
                onPayload(event)
            }
        }
    }

    /// 判定崩溃诊断是否为 OOM/Jetsam：资源异常类型 + SIGKILL 信号。
    private func isOOM(_ crash: MXCrashDiagnostic) -> Bool {
        // EXC_RESOURCE == 11；exceptionType/signal 为 NSNumber?，缺失时不判为 OOM。
        let isResourceException = crash.exceptionType?.int32Value == 11
        let isSigkill = crash.signal?.int32Value == SIGKILL
        return isResourceException && isSigkill
    }
}
