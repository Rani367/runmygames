import XCTest
@testable import RMGCore

/// Renderer detection for engines that pick their graphics API at runtime, and the scan cache.
final class DetectionTests: TempDirTestCase {
    func fixture(_ name: String) -> URL { Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)! }

    func gameDir(_ name: String = "game") throws -> URL {
        let dir = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func policy() -> RendererPolicy { RendererPolicy(paths: paths, d3dmetalAvailable: false, dxmtAvailable: true) }

    func testGodotStyleVulkanLoadedByName() throws {
        let dir = try gameDir()
        var exe = try Data(contentsOf: fixture("plain32.exe"))
        exe.append(Data("\0vulkan-1.dll\0OPENGL32.dll\0".utf8)) // what LoadLibrary would be called with
        try exe.write(to: dir.appendingPathComponent("Game.exe"))
        let d = policy().decide(game: Game(id: 1, name: "G", installDir: dir, installed: true, sizeOnDisk: 0),
                                settings: GameSettings(), compat: nil)
        XCTAssertEqual(d.apis, ["vulkan", "opengl"])
        XCTAssertEqual(d.renderer, .dxmt)
        XCTAssertTrue(d.reason.contains("Vulkan"))
    }

    func testSource2RendererModulesAndToolsSkipped() throws {
        let bin = try gameDir("game/bin/win64")
        try FileManager.default.copyItem(at: fixture("plain32.exe"), to: bin.appendingPathComponent("cs2.exe"))
        // Source 2 ships a bigger developer console next to the game.
        var big = try Data(contentsOf: fixture("plain32.exe"))
        big.append(Data(count: 2 << 20))
        try big.write(to: bin.appendingPathComponent("vconsole2.exe"))
        try Data().write(to: bin.appendingPathComponent("rendersystemdx11.dll"))
        try Data().write(to: bin.appendingPathComponent("rendersystemvulkan.dll"))
        let scan = RendererPolicy.scan(installDir: tmp.appendingPathComponent("game"))
        XCTAssertEqual(scan.mainExe?.lastPathComponent, "cs2.exe")
        XCTAssertEqual(scan.apis, ["d3d11", "vulkan"])
    }

    func testFallbacksSkipMissingRenderers() {
        let p = RendererPolicy(paths: paths, d3dmetalAvailable: false, dxmtAvailable: true)
        XCTAssertEqual(p.fallbacks(after: .dxmt), [.wined3d])
        XCTAssertEqual(p.fallbacks(after: .wined3d), [.dxmt])
    }

    func testScanCacheReusesResultUntilSteamUpdatesTheGame() throws {
        let dir = try gameDir()
        try FileManager.default.copyItem(at: fixture("dx11_12.exe"), to: dir.appendingPathComponent("Game.exe"))
        let cache = ScanCache(paths: paths)
        var game = Game(id: 5, name: "G", installDir: dir, installed: true, sizeOnDisk: 0, buildID: "1", lastUpdated: "1")
        XCTAssertEqual(cache.scan(game).apis, ["d3d11", "d3d12"])
        XCTAssertTrue(cache.url(5).exists)

        // Files change underneath without a Steam update: the cached answer stands.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Game.exe"))
        try FileManager.default.copyItem(at: fixture("plain32.exe"), to: dir.appendingPathComponent("Game.exe"))
        XCTAssertEqual(cache.scan(game).apis, ["d3d11", "d3d12"])

        // A new build id means a new scan.
        game = Game(id: 5, name: "G", installDir: dir, installed: true, sizeOnDisk: 0, buildID: "2", lastUpdated: "2")
        XCTAssertEqual(cache.scan(game).apis, [])
    }

    func testScanCacheSkipsDownloads() throws {
        let dir = try gameDir()
        try FileManager.default.copyItem(at: fixture("dx11_12.exe"), to: dir.appendingPathComponent("Game.exe"))
        let cache = ScanCache(paths: paths)
        _ = cache.scan(Game(id: 6, name: "G", installDir: dir, installed: false, sizeOnDisk: 0))
        XCTAssertFalse(cache.url(6).exists)
    }
}
