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
        }
        progress("Applying macOS integration settings…")
        try engine.importRegistry(Self.defaultsRegistry(retina: GlobalSettings.load(paths).retinaMode))
        try installShim()
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

    /// Per-executable Retina override (winemac reads AppDefaults\<exe>\Mac Driver).
    public func setRetina(_ on: Bool?, exeName: String) throws {
        let key = "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(exeName)\\Mac Driver"
        let value = on.map { "\"\($0 ? "y" : "n")\"" } ?? "-"
        try engine.importRegistry("Windows Registry Editor Version 5.00\n\n[\(key)]\n\"RetinaMode\"=\(value)\n")
    }
}
