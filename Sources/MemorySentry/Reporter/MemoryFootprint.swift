import Foundation

/// 读取 App 当前内存占用。
///
/// 使用 `task_vm_info.phys_footprint` —— 与系统 Jetsam（内存压力杀进程）的判定口径一致，
/// 比 `resident_size` 更能反映"App 实际欠系统多少物理内存"。
/// 同时尝试读取 `limit_bytes_remaining`：进程级内存上限 ≈ phys_footprint + limit_bytes_remaining。
/// 该字段在部分模拟器 / 旧 iOS 上为 0，调用方应回退到 `ProcessInfo.physicalMemory`。
public enum MemoryFootprint {

    /// 一次 task_vm_info 读取的关键字段。
    public struct Reading {
        /// 当前 phys_footprint（字节）。
        public let footprint: UInt64
        /// 进程剩余可用内存（字节）。配合 footprint 推算进程级上限；为 nil 表示系统未提供。
        public let bytesRemaining: UInt64?

        /// 进程级内存上限（字节）。`nil` 表示无法推算（应回退到 ProcessInfo.physicalMemory）。
        public var processLimit: UInt64? {
            guard let bytesRemaining else { return nil }
            return footprint + bytesRemaining
        }
    }

    /// 读取一次 task_vm_info，返回 footprint 与 bytesRemaining。读取失败返回 nil。
    public static func read() -> Reading? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // limit_bytes_remaining 在 iOS 真机为有效进程级剩余可用内存；
        // 模拟器或字段未填充时可能为 0，此时不可信，按 nil 处理由调用方回退。
        let remaining = info.limit_bytes_remaining
        let bytesRemaining: UInt64? = remaining > 0 ? UInt64(remaining) : nil
        return Reading(footprint: UInt64(info.phys_footprint), bytesRemaining: bytesRemaining)
    }

    /// 仅返回 phys_footprint（字节）。读取失败返回 nil。
    public static func current() -> UInt64? {
        read()?.footprint
    }
}
