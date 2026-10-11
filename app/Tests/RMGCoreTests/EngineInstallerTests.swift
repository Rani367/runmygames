import XCTest
@testable import RMGCore

final class EngineInstallerTests: TempDirTestCase {
    /// A fake engine + DXMT archive pair and a manifest pointing at them via file:// URLs.
    func makeAssets(engineBuild: String = "1.0-1", corruptEngineSHA: Bool = false) throws -> EngineInstaller.Manifest {
        let src = tmp.appendingPathComponent("src")
        let wine = src.appendingPathComponent("wine-cx-test/bin/wine")
        try write("#!/bin/sh\necho wine\n", to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try write("dll", to: src.appendingPathComponent("v9/x86_64-windows/d3d11.dll"))
        let engineTar = tmp.appendingPathComponent("engine.tar.gz"), dxmtTar = tmp.appendingPathComponent("dxmt.tar.gz")
        try tarball(of: src, entries: ["wine-cx-test"], to: engineTar)
        try tarball(of: src, entries: ["v9"], to: dxmtTar)
        return .init(engine: .init(name: "wine-cx-test", build: engineBuild, url: engineTar,
                                   sha256: corruptEngineSHA ? String(repeating: "0", count: 64) : try Downloader.sha256(of: engineTar),
                                   size: nil),
                     dxmt: .init(version: "v9", url: dxmtTar, sha256: try Downloader.sha256(of: dxmtTar)))
    }

    func testInstallsAndReportsUpToDate() async throws {
        let installer = EngineInstaller(paths: paths, manifest: try makeAssets())
        XCTAssertTrue(installer.needsEngine)
        XCTAssertTrue(installer.needsDXMT)
        try await installer.install()
        XCTAssertTrue(installer.engineInstalled)
        XCTAssertEqual(installer.installedBuild, "1.0-1")
        XCTAssertEqual(installer.installedDXMT, "v9")
        XCTAssertTrue(installer.upToDate)
        XCTAssertEqual(paths.engine?.lastPathComponent, "wine-cx-test")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.engines.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "staging folders cleaned up")
    }

    func testNewBuildIsAnUpdate() async throws {
        try await EngineInstaller(paths: paths, manifest: try makeAssets()).install()
        let newer = EngineInstaller(paths: paths, manifest: try makeAssets(engineBuild: "1.0-2"))
        XCTAssertTrue(newer.needsEngine)
        XCTAssertFalse(newer.needsDXMT)
    }

    func testChecksumMismatchKeepsExistingEngine() async throws {
        try await EngineInstaller(paths: paths, manifest: try makeAssets()).install()
        let bad = EngineInstaller(paths: paths, manifest: try makeAssets(engineBuild: "1.0-2", corruptEngineSHA: true))
        do {
            try await bad.install()
            XCTFail("expected a checksum error")
        } catch {
            XCTAssertTrue(RMGError.message(for: error).contains("Checksum mismatch"))
        }
        XCTAssertEqual(bad.installedBuild, "1.0-1", "old engine untouched")
    }

    func testLocalTarballMustMatchManifest() async throws {
        let m = try makeAssets()
        let other = tmp.appendingPathComponent("other.tar.gz")
        try Data("not the engine".utf8).write(to: other)
        do {
            try await EngineInstaller(paths: paths, manifest: m).install(localEngine: other)
            XCTFail("expected a mismatch error")
        } catch {}
        try await EngineInstaller(paths: paths, manifest: m).install(localEngine: m.engine.url)
        XCTAssertEqual(EngineInstaller(paths: paths, manifest: m).installedBuild, "1.0-1")
    }

    func testBundledManifestDecodes() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../engine/manifest.json").standardizedFileURL
        let m = try JSONDecoder().decode(EngineInstaller.Manifest.self, from: Data(contentsOf: file))
        XCTAssertEqual(m.engine.sha256.count, 64)
        XCTAssertTrue(m.engine.url.lastPathComponent.hasPrefix("rmg-engine-\(m.engine.name)"))
    }
}

final class DownloaderTests: TempDirTestCase {
    func testSHA256() throws {
        let f = tmp.appendingPathComponent("f")
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try Downloader.sha256(of: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testFetchVerifiesChecksum() async throws {
        let src = tmp.appendingPathComponent("src"), dest = tmp.appendingPathComponent("out/dest")
        try Data("abc".utf8).write(to: src)
        do {
            try await Downloader.fetch(src, to: dest, sha256: String(repeating: "1", count: 64))
            XCTFail("expected mismatch")
        } catch {}
        XCTAssertFalse(dest.exists)
        try await Downloader.fetch(src, to: dest, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try Data(contentsOf: dest), Data("abc".utf8))
    }
}
