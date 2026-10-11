import Foundation

public enum RMGError: Error, CustomStringConvertible, LocalizedError {
    case noEngine
    case noSteam
    case failed(String)

    public var description: String {
        switch self {
        case .noEngine:
            return "The Wine engine is not installed. Open RunMyGames.app, or run `rmg engine install`."
        case .noSteam: return "Windows Steam is not installed yet. Open RunMyGames.app, or run `rmg setup`."
        case let .failed(m): return m
        }
    }

    public var errorDescription: String? { description }

    /// A sentence fit for a status line or alert, whatever the error type.
    public static func message(for error: Error) -> String {
        if let e = error as? RMGError { return e.description }
        if let e = error as? VDF.ParseError { return e.description }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "Network error: \(ns.localizedDescription)" }
        return ns.localizedDescription
    }
}

/// Runs programs inside the RunMyGames Wine engine.
public struct Engine: Sendable {
    public let paths: Paths
    public let root: URL

    public init(paths: Paths = .shared) throws {
        guard let root = paths.engine else { throw RMGError.noEngine }
        self.paths = paths
        self.root = root
    }

    public var version: String {
        (try? String(contentsOf: root.appendingPathComponent("RMG_ENGINE_VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? root.lastPathComponent
    }

    /// The loader inside "RunMyGames Engine.app" (Game Mode + Dock identity),
    /// falling back to the plain binary.
    public var loader: URL {
        let bundled = root.appendingPathComponent("RunMyGames Engine.app/Contents/MacOS/wine")
        return bundled.exists ? bundled : root.appendingPathComponent("bin/wine")
    }

    public var wineserver: URL { root.appendingPathComponent("bin/wineserver") }

    public var d3dmetalAvailable: Bool {
        paths.d3dmetal.appendingPathComponent("external/libd3dshared.dylib").exists
    }

    public var dxmtAvailable: Bool { paths.dxmt.appendingPathComponent("x86_64-windows/d3d11.dll").exists }

    /// Base environment shared by every Wine process (Steam and games).
    public func environment(_ settings: GlobalSettings? = nil) -> [String: String] {
        let settings = settings ?? GlobalSettings.load(paths)
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("WINE") || k.hasPrefix("DYLD_") { env[k] = nil }
        env["WINEPREFIX"] = paths.prefix.path
        env["WINESERVER"] = wineserver.path
        env["WINELOADER"] = loader.path
        // The loader lives in an .app bundle, so tell it where ntdll.so etc. are.
        env["WINEDLLPATH"] = root.appendingPathComponent("lib/wine").path
        env["DYLD_FALLBACK_LIBRARY_PATH"] = root.appendingPathComponent("lib").path + ":/usr/lib"
        env["WINEDEBUG"] = env["RMG_WINEDEBUG"] ?? "-all"
        env["WINEMSYNC"] = settings.msync ? "1" : nil
        env["DOTNET_EnableWriteXorExecute"] = "0"
        env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        if d3dmetalAvailable {
            // Lets Rosetta-translated code cooperate with D3DMetal's native regions (CX does the same).
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = paths.d3dmetal.appendingPathComponent("external/libd3dshared.dylib").path
        }
        return env
    }

    /// Starts a Wine process. `wait` blocks until it exits. Output goes to `log`, to this
    /// process's own stdout/stderr with `inheritOutput` (the `rmg wine` passthrough), or nowhere.
    @discardableResult
    public func run(_ args: [String], env extra: [String: String] = [:], wait: Bool = true,
                    log: URL? = nil, cwd: URL? = nil, inheritOutput: Bool = false) throws -> Process {
        let p = Process()
        p.executableURL = loader
        p.arguments = args
        var env = environment()
        env.merge(extra) { $1 }
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        if let log {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            Self.rotate(log)
            if !log.exists { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let h = try FileHandle(forWritingTo: log)
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        } else if !inheritOutput {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        try p.run()
        if wait { p.waitUntilExit() }
        return p
    }

    /// Keeps one previous generation (`name.1`) once a log passes `limit` bytes.
    static func rotate(_ log: URL, limit: Int = 10 << 20) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: log.path))?[.size] as? Int, size > limit else { return }
        let old = log.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: log, to: old)
    }

    /// `wineserver -w` (wait for all processes) or `-k` (kill everything).
    public func wineserver(_ flag: String) {
        let p = Process()
        p.executableURL = wineserver
        p.arguments = [flag]
        p.environment = environment()
        try? p.run()
        p.waitUntilExit()
    }

    /// Imports a .reg file into the prefix registry.
    public func importRegistry(_ contents: String) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rmg-\(UUID().uuidString).reg")
        // regedit wants UTF-16LE with BOM for "Windows Registry Editor Version 5.00" files.
        var data = Data([0xFF, 0xFE])
        data.append(contents.replacingOccurrences(of: "\n", with: "\r\n").data(using: .utf16LittleEndian)!)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try run(["regedit", "/S", tmp.path])
    }
}
