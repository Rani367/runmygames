import XCTest
@testable import RMGCore

final class VDFTests: XCTestCase {
    let localconfig = #"""
    "UserLocalConfigStore"
    {
    	"Software"
    	{
    		"Valve"
    		{
    			"Steam"
    			{
    				"apps"
    				{
    					"440"
    					{
    						"LastPlayed"		"1700000000"
    						"LaunchOptions"		"-novid \"quoted\""
    					}
    					"570"
    					{
    						"LastPlayed"		"1"
    					}
    				}
    			}
    		}
    	}
    	// comment
    	"friends" [$WIN32]
    	{
    		"x"		"y"
    	}
    }
    """#

    func testParseAndLookup() throws {
        let v = try VDF.parse(localconfig)
        XCTAssertEqual(v[path: "UserLocalConfigStore", "software", "valve", "steam", "apps", "440", "LaunchOptions"]?.string,
                       #"-novid "quoted""#)
        XCTAssertEqual(v[path: "UserLocalConfigStore", "friends", "x"]?.string, "y")
    }

    func testRoundTrip() throws {
        let v = try VDF.parse(localconfig)
        XCTAssertEqual(try VDF.parse(v.serialized()), v)
    }

    func testSetCreatesPathAndKeepsCase() throws {
        var v = try VDF.parse(localconfig)
        v.set(["UserLocalConfigStore", "software", "Valve", "Steam", "apps", "999", "LaunchOptions"], .string("x"))
        XCTAssertEqual(v[path: "UserLocalConfigStore", "Software", "Valve", "Steam", "apps", "999", "LaunchOptions"]?.string, "x")
        XCTAssertTrue(v.serialized().contains("\"Software\""))
        XCTAssertFalse(v.serialized().contains("\"software\""))
    }

    func testMalformed() {
        XCTAssertThrowsError(try VDF.parse("\"a\" { \"b\" \"c\" "))
        XCTAssertThrowsError(try VDF.parse("\"a\" \"unterminated"))
    }
}

final class LaunchOptionsTests: XCTestCase {
    let shim = LaunchOptions.shimPrefix

    func testWrap() {
        XCTAssertEqual(LaunchOptions.wrap(""), shim)
        XCTAssertEqual(LaunchOptions.wrap("-dx11"), "\(shim) -dx11")
        XCTAssertEqual(LaunchOptions.wrap("FOO=1 %command% -x"), "FOO=1 \(shim) -x")
        XCTAssertEqual(LaunchOptions.wrap(LaunchOptions.wrap("-dx11")), "\(shim) -dx11", "idempotent")
    }

    func testUnwrap() {
        XCTAssertEqual(LaunchOptions.unwrap(shim), "")
        XCTAssertEqual(LaunchOptions.unwrap("\(shim) -dx11"), "%command% -dx11")
    }

    func testApplyOnlyTouchesRequestedApps() throws {
        var v = try VDF.parse(VDFTests().localconfig)
        XCTAssertTrue(try LaunchOptions.apply(to: &v, appIDs: [440, 12345]))
        let apps = v[path: "UserLocalConfigStore", "Software", "Valve", "Steam", "apps"]!
        XCTAssertEqual(apps["440"]?["LaunchOptions"]?.string, #"\#(shim) -novid "quoted""#)
        XCTAssertEqual(apps["12345"]?["LaunchOptions"]?.string, shim)
        XCTAssertNil(apps["570"]?["LaunchOptions"])
        XCTAssertEqual(apps["440"]?["LastPlayed"]?.string, "1700000000")
        XCTAssertFalse(try LaunchOptions.apply(to: &v, appIDs: [440, 12345]), "second run is a no-op")
        XCTAssertTrue(try LaunchOptions.apply(to: &v, appIDs: [440], remove: true))
        XCTAssertEqual(v[path: "UserLocalConfigStore", "Software", "Valve", "Steam", "apps", "440", "LaunchOptions"]?.string,
                       #"%command% -novid "quoted""#)
    }
}

final class PEScannerTests: XCTestCase {
    func fixture(_ name: String) -> URL { Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)! }

    func testDirectXImports() throws {
        let info = try XCTUnwrap(PEScanner.scan(fixture("dx11_12.exe")))
        XCTAssertTrue(info.is64Bit)
        XCTAssertTrue(info.imports.contains("d3d11.dll"))
        XCTAssertTrue(info.imports.contains("d3d12.dll"))
        XCTAssertTrue(info.imports.contains("kernel32.dll"))
    }

    func test32Bit() throws {
        let info = try XCTUnwrap(PEScanner.scan(fixture("plain32.exe")))
        XCTAssertFalse(info.is64Bit)
        XCTAssertFalse(info.imports.contains("d3d11.dll"))
    }

    func testRejectsNonPE() {
        XCTAssertNil(PEScanner.scan(Data("hello world, definitely not a PE file".utf8)))
    }
}

final class RendererPolicyTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rmg-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func makeGame(exe: String, as name: String, extraDirs: [String] = []) throws -> Game {
        let dir = tmp.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for d in extraDirs { try FileManager.default.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true) }
        try FileManager.default.copyItem(at: PEScannerTests().fixture(exe), to: dir.appendingPathComponent(name))
        try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent("unins000.exe"))
        return Game(id: 1, name: "Test", installDir: dir, installed: true, sizeOnDisk: 0)
    }

    func policy(d3dmetal: Bool = true) -> RendererPolicy {
        RendererPolicy(paths: Paths(home: tmp, resources: tmp), d3dmetalAvailable: d3dmetal, dxmtAvailable: true)
    }

    func testMainExecutablePrefersUnityLayout() throws {
        let g = try makeGame(exe: "plain32.exe", as: "MyGame.exe", extraDirs: ["MyGame_Data"])
        try FileManager.default.copyItem(at: PEScannerTests().fixture("dx11_12.exe"), to: g.installDir.appendingPathComponent("Other.exe"))
        XCTAssertEqual(RendererPolicy.mainExecutable(in: g.installDir)?.lastPathComponent, "MyGame.exe")
    }

    func testDX11AndDX12PrefersDXMT() throws {
        let g = try makeGame(exe: "dx11_12.exe", as: "Game.exe")
        let d = policy().decide(game: g, settings: GameSettings(), compat: nil)
        XCTAssertEqual(d.renderer, .dxmt)
        XCTAssertEqual(d.apis, ["d3d11", "d3d12"])
    }

    func testUnrealDX12PrefersD3DMetal() throws {
        let g = try makeGame(exe: "dx11_12.exe", as: "Game-Win64-Shipping.exe")
        let dir = g.installDir.appendingPathComponent("Game/Binaries/Win64")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: g.installDir.appendingPathComponent("Game-Win64-Shipping.exe"),
                                         to: dir.appendingPathComponent("Game-Win64-Shipping.exe"))
        XCTAssertEqual(policy().decide(game: g, settings: GameSettings(), compat: nil).renderer, .d3dmetal)
        try Data(repeating: 0, count: 1000).write(to: g.installDir.appendingPathComponent("Game.exe"))
        let fallback = policy(d3dmetal: false).decide(game: g, settings: GameSettings(), compat: nil)
        XCTAssertEqual(fallback.unrealStub, "Game.exe", "bootstrap stub detected")
        XCTAssertEqual(fallback.renderer, .dxmt, "falls back when D3DMetal isn't imported")
        XCTAssertEqual(fallback.args, ["-dx11"], "and keeps the Unreal game on its DX11 path")
        let env = policy(d3dmetal: false).environment(for: fallback, settings: GameSettings(), global: GlobalSettings(), compat: nil)
        XCTAssertEqual(env["RMG_ARGS"], "-dx11")
        XCTAssertNil(env["RMG_REPLACE"], "no override for an exe outside the prefix's drive_c")
    }

    func testWindowsPath() {
        let p = Paths(home: tmp, resources: tmp)
        XCTAssertEqual(p.windowsPath(p.driveC.appendingPathComponent("Program Files/Game/a.exe")), #"C:\Program Files\Game\a.exe"#)
        XCTAssertNil(p.windowsPath(URL(fileURLWithPath: "/tmp/x.exe")))
    }

    func testOverridesWin() throws {
        let g = try makeGame(exe: "dx11_12.exe", as: "Game.exe")
        var s = GameSettings()
        XCTAssertEqual(policy().decide(game: g, settings: s, compat: CompatEntry(renderer: .wined3d)).renderer, .wined3d)
        s.renderer = .d3dmetal
        XCTAssertEqual(policy().decide(game: g, settings: s, compat: CompatEntry(renderer: .wined3d)).renderer, .d3dmetal)
    }

    func testEnvironment() throws {
        let p = policy()
        let g = try makeGame(exe: "dx11_12.exe", as: "Game.exe")
        var s = GameSettings()
        s.metalHUD = true
        s.args = "-windowed"
        let d = p.decide(game: g, settings: s, compat: nil)
        let env = p.environment(for: d, settings: s, global: GlobalSettings(), compat: CompatEntry(args: "-skipintro"))
        XCTAssertEqual(env["WINEDLLPATH_PREPEND"], tmp.appendingPathComponent("renderers/dxmt").path)
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env["RMG_ARGS"], "-skipintro -windowed")
    }
}
