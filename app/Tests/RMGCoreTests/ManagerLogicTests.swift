import XCTest
@testable import RMGCore

final class ManagerLogicTests: XCTestCase {
    func testParseLastRun() {
        XCTAssertEqual(Manager.parseLastRun("exit=-1073741819 seconds=3 renderer=dxmt\n"),
                       Manager.LastRun(exitCode: -1_073_741_819, seconds: 3, renderer: "dxmt"))
        XCTAssertNil(Manager.parseLastRun("garbage"))
        XCTAssertTrue(Manager.parseLastRun("exit=1 seconds=2 renderer=dxmt")!.crashedOnStart)
        XCTAssertFalse(Manager.parseLastRun("exit=1 seconds=600 renderer=dxmt")!.crashedOnStart, "played a while")
        XCTAssertFalse(Manager.parseLastRun("exit=0 seconds=1 renderer=dxmt")!.crashedOnStart, "clean exit")
    }

    func crash(_ r: Renderer) -> Manager.LastRun { Manager.LastRun(exitCode: 5, seconds: 2, renderer: r.rawValue) }

    func testAutoFallbackTriesEachRendererOnceThenStops() throws {
        let order: [Renderer: [Renderer]] = [.dxmt: [.d3dmetal, .wined3d], .d3dmetal: [.dxmt, .wined3d], .wined3d: [.dxmt, .d3dmetal]]
        var s = GameSettings()
        var current = Renderer.dxmt
        var seen = [current]
        // Each crash moves to a renderer not tried yet...
        for _ in 0..<2 {
            let next = try XCTUnwrap(Manager.autoFallback(settings: s, compat: nil, current: current,
                                                           lastRun: crash(current), candidates: order[current]!))
            s = next
            current = try XCTUnwrap(s.autoFallback)
            XCTAssertFalse(seen.contains(current), "never goes back to a renderer that crashed")
            seen.append(current)
        }
        XCTAssertEqual(Set(seen), Set(Renderer.allCases))
        // ...and once all crashed, it stays put instead of cycling.
        let last = try XCTUnwrap(Manager.autoFallback(settings: s, compat: nil, current: current,
                                                       lastRun: crash(current), candidates: order[current]!))
        XCTAssertEqual(last.autoFallback, s.autoFallback)
        XCTAssertEqual(Set(last.triedRenderers ?? []), Set(Renderer.allCases))
    }

    func testAutoFallbackLeavesExplicitChoicesAlone() {
        var s = GameSettings()
        s.renderer = .dxmt
        XCTAssertNil(Manager.autoFallback(settings: s, compat: nil, current: .dxmt, lastRun: crash(.dxmt), candidates: [.wined3d]))
        XCTAssertNil(Manager.autoFallback(settings: GameSettings(), compat: CompatEntry(renderer: .dxmt), current: .dxmt,
                                          lastRun: crash(.dxmt), candidates: [.wined3d]), "compat list wins")
        XCTAssertNil(Manager.autoFallback(settings: GameSettings(), compat: nil, current: .d3dmetal,
                                          lastRun: crash(.dxmt), candidates: [.wined3d]), "crash was on another renderer")
        XCTAssertNil(Manager.autoFallback(settings: GameSettings(), compat: nil, current: .dxmt, lastRun: nil, candidates: [.wined3d]))
    }

    func testRetinaOps() {
        typealias S = Manager.RetinaState
        XCTAssertEqual(Manager.retinaOps(desired: nil, exe: "g.exe", applied: nil), [])
        XCTAssertEqual(Manager.retinaOps(desired: true, exe: "g.exe", applied: nil), [.set(exe: "g.exe", on: true)])
        XCTAssertEqual(Manager.retinaOps(desired: true, exe: "g.exe", applied: S(exe: "g.exe", on: true)), [], "no regedit when unchanged")
        XCTAssertEqual(Manager.retinaOps(desired: false, exe: "g.exe", applied: S(exe: "g.exe", on: true)), [.set(exe: "g.exe", on: false)])
        XCTAssertEqual(Manager.retinaOps(desired: nil, exe: "g.exe", applied: S(exe: "g.exe", on: true)), [.remove(exe: "g.exe")],
                       "back to Default removes the override")
        XCTAssertEqual(Manager.retinaOps(desired: true, exe: "new.exe", applied: S(exe: "old.exe", on: true)),
                       [.remove(exe: "old.exe"), .set(exe: "new.exe", on: true)], "game's exe changed after an update")
    }

    func testRetinaRegistry() {
        let reg = Prefix.retinaRegistry([.remove(exe: "a.exe"), .set(exe: "b.exe", on: true)])
        XCTAssertTrue(reg.hasPrefix("Windows Registry Editor Version 5.00\n"))
        XCTAssertTrue(reg.contains(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\a.exe\Mac Driver]"# + "\n\"RetinaMode\"=-"))
        XCTAssertTrue(reg.contains(#"AppDefaults\b.exe\Mac Driver]"# + "\n\"RetinaMode\"=\"y\""))
    }

    func testEnvFileCannotBeInjected() {
        let out = EnvFile.render(["GOOD": "a\nEVIL=1", "BAD KEY": "x", "1BAD": "y", "_OK2": "z"], header: ["Game\nINJECT=1"])
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["# Game INJECT=1", "GOOD=a EVIL=1", "_OK2=z"])
        XCTAssertTrue(EnvFile.isValidKey("DXMT_CONFIG"))
        XCTAssertFalse(EnvFile.isValidKey("A=B"))
        XCTAssertFalse(EnvFile.isValidKey(""))
    }
}
