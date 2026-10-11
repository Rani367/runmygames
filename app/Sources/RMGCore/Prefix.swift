import Foundation

/// The single Windows prefix ("bottle") that hosts Steam and all games.
public struct Prefix: Sendable {
    public let engine: Engine
    public var paths: Paths { engine.paths }

    public init(engine: Engine) { self.engine = engine }

    public var exists: Bool { paths.prefix.appendingPathComponent("system.reg").exists }

    public static func defaultsRegistry(retina: Bool) -> String {
        """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "LeftOptionIsAlt"="y"
        "RightOptionIsAlt"="y"
        "RetinaMode"="\(retina ? "y" : "n")"

        [HKEY_CURRENT_USER\\Control Panel\\Desktop]
        "FontSmoothing"="2"
        "FontSmoothingType"=dword:00000002
        "FontSmoothingGamma"=dword:00000578
        "FontSmoothingOrientation"=dword:00000001

        """
    }

    /// Creates (or repairs) the prefix and installs the shim. Safe to re-run.
    public func create(progress: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.prefix, withIntermediateDirectories: true)
        if !exists {
            progress("Creating Windows 10 environment…")
            // Mono/Gecko installers would pop up dialogs; Steam doesn't need them.
            try engine.run(["wineboot", "-i"], env: ["WINEDLLOVERRIDES": "mscoree,mshtml="],
                           log: paths.logs.appendingPathComponent("prefix.log"))
            engine.wineserver("-w")
            try recordEngine()
        } else {
            try upgradeIfNeeded(progress: progress)
        }
        progress("Applying macOS integration settings…")
        try engine.importRegistry(Self.defaultsRegistry(retina: GlobalSettings.load(paths).retinaMode))
        try installShim()
    }

    private var engineMarker: URL { paths.prefix.appendingPathComponent(".rmg-engine") }

    private func recordEngine() throws {
        try engine.version.write(to: engineMarker, atomically: true, encoding: .utf8)
    }

    /// After an engine update, lets the new Wine bring the prefix's builtin files and registry
    /// up to date (`wineboot -u`), as Wine itself expects. Cheap no-op otherwise.
    public func upgradeIfNeeded(progress: (String) -> Void = { _ in }) throws {
        guard exists else { return }
        let recorded = (try? String(contentsOf: engineMarker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefixes from before this marker existed were made by the current engine.
        guard let recorded else { try recordEngine(); return }
        guard recorded != engine.version else { return }
        progress("Updating the Windows environment for engine \(engine.version)…")
        try engine.run(["wineboot", "-u"], env: ["WINEDLLOVERRIDES": "mscoree,mshtml="],
                       log: paths.logs.appendingPathComponent("prefix.log"))
        engine.wineserver("-w")
        try recordEngine()
    }

    public func installShim() throws {
        let fm = FileManager.default
        for d in [paths.rmgWin, paths.gameEnvDir, paths.rmgWin.appendingPathComponent("logs")] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        guard paths.bundledShim.exists else { throw RMGError.failed("rmgshim.exe missing from \(paths.resources.path)") }
        try copyIfChanged(paths.bundledShim, to: paths.shim)
        try installRendererPlaceholders()
    }

    /// Wine only loads builtin DLLs that have a file in system32/syswow64. Renderer DLLs
    /// that replace existing Wine DLLs (d3d11, dxgi, d3d12) already have one; DXMT's helper
    /// winemetal.dll does not. The actual code is still loaded per game from WINEDLLPATH_PREPEND.
    public func installRendererPlaceholders() throws {
        let win = paths.driveC.appendingPathComponent("windows")
        for (arch, dir) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            let src = paths.dxmt.appendingPathComponent("\(arch)/winemetal.dll")
            if src.exists { try copyIfChanged(src, to: win.appendingPathComponent("\(dir)/winemetal.dll")) }
        }
    }

    private func copyIfChanged(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.contentsEqual(atPath: src.path, andPath: dst.path) { return }
        try? fm.removeItem(at: dst)
        try fm.copyItem(at: src, to: dst)
    }

    /// Per-executable Retina overrides (winemac reads AppDefaults\<exe>\Mac Driver), in one regedit run.
    public func applyRetina(_ ops: [Manager.RetinaOp]) throws {
        guard !ops.isEmpty else { return }
        try engine.importRegistry(Self.retinaRegistry(ops))
    }

    static func retinaRegistry(_ ops: [Manager.RetinaOp]) -> String {
        var out = "Windows Registry Editor Version 5.00\n"
        for op in ops {
            let (exe, value): (String, String)
            switch op {
            case let .set(e, on): (exe, value) = (e, on ? "\"y\"" : "\"n\"")
            case let .remove(e): (exe, value) = (e, "-")
            }
            out += "\n[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(exe)\\Mac Driver]\n\"RetinaMode\"=\(value)\n"
        }
        return out
    }
}
