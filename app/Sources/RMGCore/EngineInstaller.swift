import Foundation

/// Installs the prebuilt Wine engine and DXMT pinned in engine/manifest.json.
/// Building from source (engine/install-engine.sh) stays available for developers.
public struct EngineInstaller: Sendable {
    public struct Manifest: Codable, Equatable, Sendable {
        public struct EngineAsset: Codable, Equatable, Sendable {
            /// Folder name inside engines/ and at the top of the tarball, e.g. "wine-cx-26.3.0".
            public var name: String
            /// Release of that engine build, e.g. "26.3.0-1"; bumps when we rebuild the same Wine.
            public var build: String
            public var url: URL
            public var sha256: String
            public var size: Int64?
        }

        public struct DXMTAsset: Codable, Equatable, Sendable {
            public var version: String
            public var url: URL
            public var sha256: String
        }

        public var engine: EngineAsset
        public var dxmt: DXMTAsset
    }

    public enum Step: Sendable {
        case downloading(String, Double?)
        case installing(String)
    }

    public let paths: Paths
    public let manifest: Manifest

    public init(paths: Paths = .shared) throws {
        self.paths = paths
        guard let data = try? Data(contentsOf: paths.engineManifest) else {
            throw RMGError.failed("Engine manifest missing at \(paths.engineManifest.path).")
        }
        manifest = try JSONDecoder().decode(Manifest.self, from: data)
    }

    public init(paths: Paths, manifest: Manifest) {
        self.paths = paths
        self.manifest = manifest
    }

    var engineDir: URL { paths.engines.appendingPathComponent(manifest.engine.name) }
    var buildMarker: URL { engineDir.appendingPathComponent("RMG_ENGINE_BUILD") }

    /// Build string of the installed prebuilt engine (nil if missing or built from source).
    public var installedBuild: String? {
        (try? String(contentsOf: buildMarker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var engineInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: engineDir.appendingPathComponent("bin/wine").path)
    }

    public var installedDXMT: String? {
        guard paths.dxmt.appendingPathComponent("x86_64-windows/d3d11.dll").exists else { return nil }
        return (try? String(contentsOf: paths.dxmt.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    /// Something to download: no engine at all, a newer prebuilt build, or a different DXMT.
    /// A source-built engine of the same Wine version counts as current.
    public var needsEngine: Bool {
        if !engineInstalled { return true }
        if let b = installedBuild { return b != manifest.engine.build }
        return false
    }

    public var needsDXMT: Bool { installedDXMT != manifest.dxmt.version }
    public var upToDate: Bool { !needsEngine && !needsDXMT }

    /// Downloads, verifies and installs whatever is missing or outdated.
    /// `localEngine` installs from an already downloaded tarball (still checksum-verified).
    public func install(localEngine: URL? = nil, force: Bool = false,
                        progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws {
        if force || needsDXMT { try await installDXMT(progress: progress) }
        if force || needsEngine || localEngine != nil { try await installEngine(from: localEngine, progress: progress) }
    }

    func installDXMT(progress: @escaping @Sendable (Step) -> Void) async throws {
        let m = manifest.dxmt
        let file = paths.cache.appendingPathComponent("downloads/dxmt-\(m.version).tar.gz")
        try await fetchCached(m.url, to: file, sha256: m.sha256) { progress(.downloading("DXMT \(m.version)", $0)) }
        progress(.installing("DXMT \(m.version)"))
        let staging = try extract(file, into: paths.renderers, stripComponents: 1)
        defer { try? FileManager.default.removeItem(at: staging) }
        guard staging.appendingPathComponent("x86_64-windows/d3d11.dll").exists else {
            throw RMGError.failed("The DXMT archive has an unexpected layout.")
        }
        try m.version.write(to: staging.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        try replace(paths.dxmt, with: staging)
        try? FileManager.default.removeItem(at: file)
    }

    func installEngine(from local: URL?, progress: @escaping @Sendable (Step) -> Void) async throws {
        let m = manifest.engine
        let label = "Wine engine \(m.build)"
        let file: URL
        if let local {
            progress(.installing(label))
            guard try Downloader.sha256(of: local).caseInsensitiveCompare(m.sha256) == .orderedSame else {
                throw RMGError.failed("\(local.lastPathComponent) does not match the engine this version of RunMyGames expects (\(m.build)).")
            }
            file = local
        } else {
            file = paths.cache.appendingPathComponent("downloads/\(m.url.lastPathComponent)")
            try await fetchCached(m.url, to: file, sha256: m.sha256) { progress(.downloading(label, $0)) }
        }
        progress(.installing(label))
        try FileManager.default.createDirectory(at: paths.engines, withIntermediateDirectories: true)
        let staging = try extract(file, into: paths.engines, stripComponents: 0)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unpacked = staging.appendingPathComponent(m.name)
        guard FileManager.default.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/wine").path) else {
            throw RMGError.failed("The engine archive has an unexpected layout (no \(m.name)/bin/wine).")
        }
        try m.build.write(to: unpacked.appendingPathComponent("RMG_ENGINE_BUILD"), atomically: true, encoding: .utf8)
        try replace(engineDir, with: unpacked)
        if local == nil { try? FileManager.default.removeItem(at: file) }
    }

    /// Reuses a previously downloaded file when its checksum still matches (resumed setups).
    private func fetchCached(_ url: URL, to file: URL, sha256: String, progress: @escaping DownloadProgress) async throws {
        if file.exists, (try? Downloader.sha256(of: file))?.caseInsensitiveCompare(sha256) == .orderedSame { return }
        try await Downloader.fetch(url, to: file, sha256: sha256, progress: progress)
    }

    /// Unpacks into a hidden staging folder next to the destination (same volume, so the
    /// final rename is atomic) and returns that folder.
    private func extract(_ archive: URL, into parent: URL, stripComponents: Int) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var args = ["-xf", archive.path, "-C", staging.path]
        if stripComponents > 0 { args += ["--strip-components", "\(stripComponents)"] }
        let status = Shell.run("/usr/bin/tar", args)
        guard status == 0 else {
            try? fm.removeItem(at: staging)
            throw RMGError.failed("Could not unpack \(archive.lastPathComponent) (tar exit \(status)).")
        }
        // Archives fetched with a browser carry quarantine; it would trigger Gatekeeper per dylib.
        Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])
        return staging
    }

    private func replace(_ dest: URL, with new: URL) throws {
        let fm = FileManager.default
        let old = dest.deletingLastPathComponent().appendingPathComponent(".old-\(UUID().uuidString)")
        if dest.exists { try fm.moveItem(at: dest, to: old) }
        do {
            try fm.moveItem(at: new, to: dest)
        } catch {
            if old.exists { try? fm.moveItem(at: old, to: dest) }
            throw error
        }
        try? fm.removeItem(at: old)
    }
}

/// Tiny helpers around Process for system tools.
public enum Shell {
    /// Runs a tool with output discarded; returns its exit status (-1 if it could not start).
    @discardableResult
    public static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Runs a tool and returns its standard output (nil if it failed).
    public static func output(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Single-quotes a string for /bin/sh.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
