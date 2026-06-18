import Foundation

/// App 内存现场快照。在超阈值那一刻采集，回答"内存现在花在哪类区域"。
///
/// 不依赖业务登记：通过 `vm_region_recurse_64` 遍历进程全部内存区域，按系统 VM tag 聚合。
/// 因此 Lottie / 系统解码的图片等"业务侧拿不到"的分配，也能在 `imageLikeBytes` 里被统计到
/// （能给出类别总量，但定位不到具体对象 / 调用栈——那需要 Instruments / MetricKit）。
public struct MemorySnapshot: Sendable {

    /// 按 VM tag 聚合的一组内存区域。
    public struct RegionGroup: Sendable {
        public let tag: UInt32
        public let name: String
        public let bytes: UInt64
        public let regionCount: Int
    }

    /// 单块超过阈值的内存区域明细。
    ///
    /// 注意：一块 VM region 不等于一个对象。大位图 / 大 Data buffer 通常独占一块大 region，能精准对应；
    /// 而 malloc 小堆区一块里含大量小对象，此时 `bytes` 是"该堆区总量"而非单个对象。
    public struct LargeRegion: Sendable {
        /// 区域起始虚拟地址（用于和 Instruments / vmmap 交叉比对）。
        public let address: UInt64
        public let bytes: UInt64
        public let tag: UInt32
        public let name: String
    }

    /// 按 VM tag 推断的区域归类。
    public enum RegionKind: String, Sendable {
        /// 图像数据：CoreGraphics / ImageIO / IOKit 位图。
        case image
        /// 堆内存：malloc 各档（含 Data / 自定义 buffer）。
        case heap
        /// 其他未识别的 VM tag。
        case unknown
    }

    /// 一块大区域的归因推测。
    ///
    /// `kind` 来自 VM tag（如 CoreGraphics → image），tag 层面较可信；但"这块区域具体对应哪个对象"
    /// 是启发式推测，把握度由 `confidence` 标注，勿当确定结论。
    public struct RegionCorrelation: Sendable {
        public enum Confidence: String, Sendable {
            /// VM tag 明确指向某类（如图像 tag），归类可信。
            case high
            /// tag 可推断但不指向具体对象（如堆区可能含多个对象）。
            case medium
            /// 仅给出未知归类。
            case low
        }

        public let region: LargeRegion
        /// 据 VM tag 推断的区域类。
        public let kind: RegionKind
        public let confidence: Confidence
        /// 人类可读的归因说明与排查建议。
        public let note: String
    }

    /// phys_footprint（与 Jetsam 口径一致）。
    public let footprint: UInt64
    /// 物理驻留内存。
    public let residentSize: UInt64
    /// 虚拟地址空间大小。
    public let virtualSize: UInt64
    /// 已被压缩的内存（计入 footprint）。
    public let compressed: UInt64
    /// 按 VM tag 聚合的区域分组，按字节降序。
    public let regionGroups: [RegionGroup]
    /// 单块超过阈值的大区域明细，按字节降序。
    public let largeRegions: [LargeRegion]
    /// 采集时使用的单块大区域阈值（字节）。
    public let largeRegionThreshold: UInt64

    /// 图像类内存合计（CoreGraphics / ImageIO / IOKit），含第三方与系统解码。
    public var imageLikeBytes: UInt64 {
        regionGroups
            .filter { Self.isImageTag($0.tag) }
            .reduce(0) { $0 + $1.bytes }
    }

    /// 堆（malloc 各档）合计。
    public var heapBytes: UInt64 {
        regionGroups
            .filter { Self.isMallocTag($0.tag) }
            .reduce(0) { $0 + $1.bytes }
    }

    /// 采集当前进程的内存快照。
    /// - Parameter largeRegionThreshold: 单块区域超过此字节数即收入 `largeRegions` 明细，默认 10MB。
    public static func capture(
        largeRegionThreshold: UInt64 = 10 * 1024 * 1024
    ) -> MemorySnapshot {
        let vm = readTaskVMInfo()
        let scan = scanRegions(largeRegionThreshold: largeRegionThreshold)
        return MemorySnapshot(
            footprint: vm.footprint,
            residentSize: vm.resident,
            virtualSize: vm.virtual,
            compressed: vm.compressed,
            regionGroups: scan.groups,
            largeRegions: scan.largeRegions,
            largeRegionThreshold: largeRegionThreshold
        )
    }

    /// 把每块大区域归类到 `RegionKind`，给出归因推测。按区域字节降序。
    public func correlations() -> [RegionCorrelation] {
        largeRegions.map { region in
            let kind = Self.kind(forTag: region.tag)
            let confidence: RegionCorrelation.Confidence
            let note: String
            switch kind {
            case .image:
                confidence = .high
                note = "图像 tag → 大概率是位图（自有 UIImage 或第三方 / 系统解码，如 Lottie、SDWebImage 内部）"
            case .heap:
                confidence = .medium
                note = "堆区，可能含 Data / 自定义 buffer；一块含多个对象，仅到 region 粒度。可用地址配合 vmmap / Instruments 深挖"
            case .unknown:
                confidence = .low
                note = "未归类 tag(\(region.tag))，建议用 0x\(String(region.address, radix: 16)) 在 vmmap 输出中比对"
            }
            return RegionCorrelation(region: region, kind: kind, confidence: confidence, note: note)
        }
    }

    /// 生成可直接打日志 / 上报的诊断摘要：全景 + Top-N 区域 + 图像/堆合计。
    public func diagnosticSummary(topRegions: Int = 8) -> String {
        func mb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1024 / 1024) }
        var lines: [String] = []
        lines.append("===== MemorySentry 内存现场 =====")
        lines.append("footprint=\(mb(footprint))MB resident=\(mb(residentSize))MB virtual=\(mb(virtualSize))MB compressed=\(mb(compressed))MB")
        lines.append("图像类合计=\(mb(imageLikeBytes))MB  堆合计=\(mb(heapBytes))MB")
        lines.append("--- Top \(topRegions) 区域（按字节）---")
        for g in regionGroups.prefix(topRegions) {
            lines.append("  \(g.name): \(mb(g.bytes))MB (\(g.regionCount) 块)")
        }
        if !largeRegions.isEmpty {
            lines.append("--- 单块 >= \(mb(largeRegionThreshold))MB 的大区域（含归因推测）---")
            for c in correlations().prefix(topRegions) {
                lines.append("  \(c.region.name): \(mb(c.region.bytes))MB @ 0x\(String(c.region.address, radix: 16)) [\(c.kind.rawValue) | \(c.confidence.rawValue)] \(c.note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func readTaskVMInfo() -> (footprint: UInt64, resident: UInt64, virtual: UInt64, compressed: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0, 0) }
        return (UInt64(info.phys_footprint), info.resident_size, info.virtual_size, info.compressed)
    }

    /// 遍历全部 VM region：按 user_tag 聚合，同时挑出单块超阈值的大区域。
    private static func scanRegions(
        largeRegionThreshold: UInt64
    ) -> (groups: [RegionGroup], largeRegions: [LargeRegion]) {
        var byTag: [UInt32: (bytes: UInt64, count: Int)] = [:]
        var large: [LargeRegion] = []
        // 用 vm_region_recurse_64（iOS 公开 API，对应 mach_vm_* 仅 macOS 暴露）；
        // 64 位设备上 vm_address_t / vm_size_t 均为 64 位，无精度损失。
        var address: vm_address_t = 0
        var depth: natural_t = 0

        while true {
            var size: vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    vm_region_recurse_64(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { break }

            if info.is_submap != 0 {
                depth += 1
                continue
            }
            let tag = info.user_tag
            let regionBytes = UInt64(size)
            var entry = byTag[tag] ?? (0, 0)
            entry.bytes += regionBytes
            entry.count += 1
            byTag[tag] = entry

            if regionBytes >= largeRegionThreshold {
                large.append(LargeRegion(address: UInt64(address), bytes: regionBytes, tag: tag, name: tagName(tag)))
            }
            address += size
        }

        let groups = byTag
            .map { RegionGroup(tag: $0.key, name: tagName($0.key), bytes: $0.value.bytes, regionCount: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
        large.sort { $0.bytes > $1.bytes }
        return (groups, large)
    }

    private static func isImageTag(_ tag: UInt32) -> Bool {
        let imageTags: Set<Int32> = [VM_MEMORY_COREGRAPHICS, VM_MEMORY_IMAGEIO, VM_MEMORY_IOKIT]
        return imageTags.contains(Int32(tag))
    }

    /// 据 VM tag 归类区域：图像类 tag → .image，堆 tag → .heap，其余 → .unknown。
    private static func kind(forTag tag: UInt32) -> RegionKind {
        if isImageTag(tag) { return .image }
        if isMallocTag(tag) { return .heap }
        return .unknown
    }

    private static func isMallocTag(_ tag: UInt32) -> Bool {
        let mallocTags: Set<Int32> = [
            VM_MEMORY_MALLOC, VM_MEMORY_MALLOC_SMALL, VM_MEMORY_MALLOC_LARGE,
            VM_MEMORY_MALLOC_TINY, VM_MEMORY_MALLOC_HUGE, VM_MEMORY_MALLOC_NANO,
            VM_MEMORY_REALLOC
        ]
        return mallocTags.contains(Int32(tag))
    }

    /// 把 VM user_tag 翻译为可读名称。覆盖常见 tag，其余回退到 "tag #n"。
    private static func tagName(_ tag: UInt32) -> String {
        switch Int32(tag) {
        case 0: return "unknown"
        case VM_MEMORY_MALLOC: return "malloc"
        case VM_MEMORY_MALLOC_SMALL: return "malloc_small"
        case VM_MEMORY_MALLOC_LARGE: return "malloc_large"
        case VM_MEMORY_MALLOC_TINY: return "malloc_tiny"
        case VM_MEMORY_MALLOC_HUGE: return "malloc_huge"
        case VM_MEMORY_MALLOC_NANO: return "malloc_nano"
        case VM_MEMORY_REALLOC: return "realloc"
        case VM_MEMORY_STACK: return "stack"
        case VM_MEMORY_COREGRAPHICS: return "CoreGraphics"
        case VM_MEMORY_IMAGEIO: return "ImageIO"
        case VM_MEMORY_IOKIT: return "IOKit"
        case VM_MEMORY_CORESERVICES: return "CoreServices"
        case VM_MEMORY_FOUNDATION: return "Foundation"
        case VM_MEMORY_LAYERKIT: return "CoreAnimation"
        case VM_MEMORY_SQLITE: return "SQLite"
        case VM_MEMORY_DYLIB: return "dylib"
        case VM_MEMORY_OS_ALLOC_ONCE: return "os_alloc_once"
        default: return "tag #\(tag)"
        }
    }
}
