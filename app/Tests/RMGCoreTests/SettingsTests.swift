import XCTest
@testable import RMGCore

final class SettingsTests: TempDirTestCase {
    func testGlobalSettingsFromOlderVersionKeepTheirValues() throws {
        // settings.json as written by RunMyGames before checkForUpdates/lastUpdateCheck existed.
        let old = #"{"idleSeconds":120,"metalHUD":true,"msync":false,"quitSteamWhenIdle":false,"retinaMode":true,"steamArgs":["-x"]}"#
        let g = try JSON.decoder.decode(GlobalSettings.self, from: Data(old.utf8))
        XCTAssertTrue(g.metalHUD)
        XCTAssertTrue(g.retinaMode)
        XCTAssertFalse(g.msync)
        XCTAssertEqual(g.idleSeconds, 120)
        XCTAssertEqual(g.steamArgs, ["-x"])
        XCTAssertTrue(g.checkForUpdates, "new keys take their defaults")
        XCTAssertNil(g.lastUpdateCheck)
    }

    func testGlobalSettingsRoundTrip() throws {
        var g = GlobalSettings()
        g.lastUpdateCheck = Date(timeIntervalSince1970: 1_800_000_000)
        g.idleSeconds = 30
        try g.save(paths)
        XCTAssertEqual(GlobalSettings.load(paths), g)
    }

    func testGameSettingsFromOlderVersion() throws {
        let old = #"{"args":"-nojoy -high","env":{"DXMT_CONFIG":"d3d11.metalSpatialUpscaleFactor=1.5"},"metalFX":true}"#
        let s = try JSON.decoder.decode(GameSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.args, "-nojoy -high")
        XCTAssertEqual(s.metalFX, true)
        XCTAssertNil(s.triedRenderers)
    }

    func testResetRendererForgetsCrashHistory() {
        var s = GameSettings()
        s.renderer = .dxmt
        s.autoFallback = .wined3d
        s.triedRenderers = [.d3dmetal]
        s.resetRenderer()
        XCTAssertEqual(s, GameSettings())
    }

    func testBundledCompatListIsValid() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../compat/games.json").standardizedFileURL
        let db = try CompatDB.parse(Data(contentsOf: file))
        XCTAssertFalse(db.isEmpty)
        XCTAssertNotNil(db[440]?.renderer)
    }

    func testCompatRejectsNonNumericKeys() {
        XCTAssertThrowsError(try CompatDB.parse(Data(#"{"tf2": {"renderer": "dxmt"}}"#.utf8)))
        XCTAssertThrowsError(try CompatDB.parse(Data(#"{"440": {"renderer": "vulkan"}}"#.utf8)), "unknown renderer")
    }
}
