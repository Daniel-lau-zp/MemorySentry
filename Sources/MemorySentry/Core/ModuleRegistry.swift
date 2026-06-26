import Foundation

/// 一条模块注册记录：模块在某时刻登记、尚未释放。
///
/// 由 opt-in 增量归因线使用——`MemorySentry.enterModule` 写入、`leaveModule` 删除。
public struct RegisteredModule: Sendable {
    /// 模块名（注册键）。同名重复 enter 以最后一次为准（覆盖时间戳与 metadata）。
    public let name: String
    /// 注册时刻。嫌疑圈定按此与"上一拍 / 本拍轮询时刻"比对。
    public let registeredAt: Date
    /// 接入方注册时附带的元信息（版本、子功能开关等）——注册时通道。
    public let metadata: [String: String]

    public init(name: String, registeredAt: Date, metadata: [String: String]) {
        self.name = name
        self.registeredAt = registeredAt
        self.metadata = metadata
    }
}

/// 模块注册表。
///
/// **自带独立 `NSLock`**，与 `MemorySentry` 主锁解耦：`enter` / `leave` 可能从任意线程（含主线程）
/// 高频调用，独立锁让其只与"读取 registry 快照"竞争、临界区极短，不阻塞轮询判定的重临界区。
/// "未释放" = 仍在表内（`leave` 即从表内删除）。
final class ModuleRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var modules: [String: RegisteredModule] = [:]

    /// 标记模块进入。同名覆盖（刷新时间戳 + metadata）。
    func enter(_ name: String, metadata: [String: String], at date: Date) {
        let module = RegisteredModule(name: name, registeredAt: date, metadata: metadata)
        lock.lock(); modules[name] = module; lock.unlock()
    }

    /// 标记模块离开（从表内删除即视为已释放）。幂等。
    func leave(_ name: String) {
        lock.lock(); modules[name] = nil; lock.unlock()
    }

    /// 当前存活（已注册未释放）模块全集快照。锁外使用。
    func liveSnapshot() -> [RegisteredModule] {
        lock.lock(); defer { lock.unlock() }
        return Array(modules.values)
    }
}
