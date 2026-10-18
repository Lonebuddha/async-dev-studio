import StudioPlatform

final class MemoryTests {
    func testReadsLiveProcessMemory() throws {
        let bytes = ProcessMemory.currentFootprintBytes()
        try expectNotNil(bytes)
        try expectTrue((bytes ?? 0) > 0)
    }
}
