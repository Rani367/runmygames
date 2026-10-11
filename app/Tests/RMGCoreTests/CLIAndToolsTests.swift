import XCTest
@testable import RMGCore

final class CLIParsingTests: XCTestCase {
    func testGameSettings() throws {
        var s = GameSettings()
        for kv in ["renderer=DXMT", "hud=on", "metalfx=off", "retina=default", "args=-skipintro -w", "env.DXVK_HUD=1"] {
            try CLIParsing.applyGameSetting(kv, to: &s)
        }
        XCTAssertEqual(s.renderer, .dxmt)
        XCTAssertEqual(s.metalHUD, true)
        XCTAssertEqual(s.metalFX, false)
        XCTAssertNil(s.retinaMode)
        XCTAssertEqual(s.args, "-skipintro -w")
        XCTAssertEqual(s.env, ["DXVK_HUD": "1"])
        try CLIParsing.applyGameSetting("env.DXVK_HUD=", to: &s)
        XCTAssertNil(s.env, "empty value removes the variable")
        s.autoFallback = .wined3d
        try CLIParsing.applyGameSetting("renderer=auto", to: &s)
        XCTAssertNil(s.renderer)
        XCTAssertNil(s.autoFallback)
    }

    func testGameSettingErrors() {
        var s = GameSettings()
        XCTAssertThrowsError(try CLIParsing.applyGameSetting("hud=maybe", to: &s))
        XCTAssertThrowsError(try CLIParsing.applyGameSetting("renderer=vulkan", to: &s))
        XCTAssertThrowsError(try CLIParsing.applyGameSetting("color=blue", to: &s))
        XCTAssertThrowsError(try CLIParsing.applyGameSetting("env.BAD NAME=1", to: &s))
        XCTAssertThrowsError(try CLIParsing.applyGameSetting("noequals", to: &s))
    }

    func testGlobalSettings() throws {
        var g = GlobalSettings()
        try CLIParsing.applyGlobalSetting("idle=90", to: &g)
        try CLIParsing.applyGlobalSetting("quit-steam=off", to: &g)
        try CLIParsing.applyGlobalSetting("updates=no", to: &g)
        XCTAssertEqual(g.idleSeconds, 90)
        XCTAssertFalse(g.quitSteamWhenIdle)
        XCTAssertFalse(g.checkForUpdates)
        XCTAssertThrowsError(try CLIParsing.applyGlobalSetting("idle=-1", to: &g))
        XCTAssertThrowsError(try CLIParsing.applyGlobalSetting("hud=sometimes", to: &g))
        XCTAssertTrue(CLIParsing.describe(g).contains("idle=90"))
    }
}

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(Updater.isNewer("2", than: "1.9"))
        XCTAssertFalse(Updater.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0.0-beta", than: "1.0.0"))
    }
}

final class LauncherTests: TempDirTestCase {
    func testScriptIsValidShellForAwkwardNames() throws {
        let factory = LauncherFactory(paths: paths)
        let game = Game(id: 42, name: "Tom's \"Game\"\n$(rm -rf ~) `x` \\ Edition", installDir: tmp, installed: true, sizeOnDisk: 0)
        let script = factory.script(for: game)
        XCTAssertTrue(script.contains("launch 42 --watch --gui"))
        let file = tmp.appendingPathComponent("launch.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", file.path] // parse only
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        // The name only appears in the comment and inside the single-quoted osascript argument,
        // which must not be broken out of.
        for line in script.components(separatedBy: "\n") where line.contains("rm -rf") {
            if line.hasPrefix("#") { continue }
            XCTAssertTrue(line.hasPrefix("osascript -e '"), line)
            XCTAssertEqual(line.filter { $0 == "'" }.count, 2, line)
        }
        XCTAssertTrue(Shell.quote("it's").elementsEqual(#"'it'\''s'"#))
    }

    func testPruneRemovesUninstalledGames() throws {
        let p = paths
        for (name, id) in [("Keep", 1), ("Gone", 2)] {
            let plist = p.launchers.appendingPathComponent("\(name).app/Contents/Info.plist")
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            (["RMGAppID": id] as NSDictionary).write(to: plist, atomically: true)
        }
        try FileManager.default.createDirectory(at: p.launchers.appendingPathComponent("Other.app"), withIntermediateDirectories: true)
        XCTAssertEqual(LauncherFactory(paths: p).prune(keeping: [1]), ["Gone"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: p.launchers.path).sorted(), ["Keep.app", "Other.app"],
                       "apps that are not RunMyGames launchers are left alone")
    }
}

final class UninstallerTests: TempDirTestCase {
    func testTargetsStayInsideTheGivenHome() throws {
        let p = paths
        let fm = FileManager.default
        try fm.createDirectory(at: p.launchers, withIntermediateDirectories: true)
        try fm.createDirectory(at: p.home, withIntermediateDirectories: true)
        try fm.createDirectory(at: p.logs, withIntermediateDirectories: true)
        let bin = p.userHome.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bin.appendingPathComponent("rmg").path,
                                  withDestinationPath: "/Applications/RunMyGames.app/Contents/MacOS/rmg")

        let u = Uninstaller(paths: p)
        XCTAssertEqual(Set(u.targets(all: false).map(\.lastPathComponent)), ["RunMyGames", "rmg"])
        XCTAssertTrue(u.targets(all: true).contains(p.home))
        for t in u.targets(all: true) { XCTAssertTrue(t.path.hasPrefix(tmp.path), "\(t.path) is outside the test folder") }

        u.run(all: true) { _ in }
        XCTAssertFalse(p.home.exists)
        XCTAssertFalse(p.launchers.exists)
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("rmg").path))
    }

    func testForeignCLILinkIsKept() throws {
        let p = paths
        let bin = p.userHome.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("rmg").path, withDestinationPath: "/usr/local/bin/something-else")
        XCTAssertFalse(Uninstaller(paths: p).targets(all: false).contains { $0.lastPathComponent == "rmg" })
    }
}
