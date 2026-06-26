import Foundation

/// MemorySentry 事件观察者。可挂多个 observer（控制台日志 / 埋点 / 告警弹窗）。
///
/// 回调在监视内部的串行队列触发，不保证在主线程。observer 若要操作 UI 需自行切回主线程。
public protocol MemorySentryObserver: AnyObject, Sendable {
    /// App 整体内存超过字节阈值时触发。
    func memorySentry(didExceedAppFootprint event: AppFootprintEvent)
    /// 内存占用率跨越压力阈值时触发（warning / critical 各自独立做边沿迟滞）。
    func memorySentry(didCrossMemoryPressure event: MemoryPressureEvent)
    /// MetricKit 兜底线收到系统诊断 / 指标负载（OOM 或内存峰值）时触发。
    func memorySentry(didReceiveMetricKitPayload event: MetricKitEvent)
    /// 【增量归因线，opt-in】相邻两拍 footprint 涨幅超增量阈值时触发（启动宽限窗口之后）。
    /// 携带嫌疑模块（时间相关性线索）与接入方补充信息。
    func memorySentry(didDetectMemoryGrowth event: MemoryGrowthEvent)
}

public extension MemorySentryObserver {
    func memorySentry(didExceedAppFootprint event: AppFootprintEvent) {}
    func memorySentry(didCrossMemoryPressure event: MemoryPressureEvent) {}
    func memorySentry(didReceiveMetricKitPayload event: MetricKitEvent) {}
    func memorySentry(didDetectMemoryGrowth event: MemoryGrowthEvent) {}
}
