import XCTest
@testable import MemorySentry

/// 内存现场快照测试：footprint 可读、按 VM tag 聚合、大区域捕获、归因推测置信度。
final class MemorySnapshotTests: XCTestCase {

    func testFootprintReadable() {
        XCTAssertNotNil(MemoryFootprint.current())
        XCTAssertGreaterThan(MemoryFootprint.current() ?? 0, 0)
    }

    func testReadIncludesProcessLimitOrFallback() {
        // read() 总能拿到 footprint；processLimit 在模拟器上可能为 nil（系统不填）。
        let r = MemoryFootprint.read()
        XCTAssertNotNil(r)
        XCTAssertGreaterThan(r?.footprint ?? 0, 0)
    }

    func testSnapshotCaptureHasRegions() {
        let snapshot = MemorySnapshot.capture()
        XCTAssertGreaterThan(snapshot.footprint, 0)
        XCTAssertFalse(snapshot.regionGroups.isEmpty)
        XCTAssertGreaterThan(snapshot.heapBytes, 0)
        XCTAssertFalse(snapshot.diagnosticSummary().isEmpty)
    }

    func testSnapshotCapturesLargeRegion() {
        let blockSize = 40 * 1024 * 1024
        let ptr = malloc(blockSize)!
        defer { free(ptr) }
        // 写入触发实际驻留，确保独立成块大 region。
        memset(ptr, 0xAB, blockSize)

        let snapshot = MemorySnapshot.capture(largeRegionThreshold: 20 * 1024 * 1024)
        XCTAssertFalse(snapshot.largeRegions.isEmpty, "应捕获到 40MB 的大区域")
        XCTAssertTrue(snapshot.largeRegions.allSatisfy { $0.bytes >= 20 * 1024 * 1024 })
        XCTAssertTrue(
            snapshot.largeRegions.contains { $0.bytes >= UInt64(blockSize) },
            "明细中应有 >= 40MB 的区域"
        )
    }

    private func makeSnapshot(largeRegions: [MemorySnapshot.LargeRegion]) -> MemorySnapshot {
        MemorySnapshot(
            footprint: 0, residentSize: 0, virtualSize: 0, compressed: 0,
            regionGroups: [],
            largeRegions: largeRegions,
            largeRegionThreshold: 10 * 1024 * 1024
        )
    }

    func testCorrelationImageTagIsHighConfidence() {
        let region = MemorySnapshot.LargeRegion(
            address: 0x1000, bytes: 64 * 1024 * 1024,
            tag: UInt32(VM_MEMORY_COREGRAPHICS), name: "CoreGraphics"
        )
        let c = makeSnapshot(largeRegions: [region]).correlations().first
        XCTAssertEqual(c?.kind, .image)
        XCTAssertEqual(c?.confidence, .high)
    }

    func testCorrelationHeapIsMediumConfidence() {
        let region = MemorySnapshot.LargeRegion(
            address: 0x2000, bytes: 40 * 1024 * 1024,
            tag: UInt32(VM_MEMORY_MALLOC_LARGE), name: "malloc_large"
        )
        let c = makeSnapshot(largeRegions: [region]).correlations().first
        XCTAssertEqual(c?.kind, .heap)
        XCTAssertEqual(c?.confidence, .medium)
    }

    func testCorrelationUnknownTagIsLowConfidence() {
        let region = MemorySnapshot.LargeRegion(
            address: 0x3000, bytes: 30 * 1024 * 1024,
            tag: 9999, name: "tag #9999"
        )
        let c = makeSnapshot(largeRegions: [region]).correlations().first
        XCTAssertEqual(c?.kind, .unknown)
        XCTAssertEqual(c?.confidence, .low)
    }
}
