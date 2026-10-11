import XCTest
@testable import RMGCore

final class SteamLibraryTests: TempDirTestCase {
    func manifest(_ id: Int, _ name: String, dir: String, flags: Int = 4, build: String = "100") -> String {
        """
        "AppState"
        {
        	"appid"		"\(id)"
        	"name"		"\(name)"
        	"StateFlags"		"\(flags)"
        	"installdir"		"\(dir)"
        	"SizeOnDisk"		"1234"
        	"buildid"		"\(build)"
        	"LastUpdated"		"1700000000"
        }
        """
    }

    func testGamesAcrossLibraries() throws {
        let p = paths
        let main = p.steamDir.appendingPathComponent("steamapps")
        let extra = tmp.appendingPathComponent("External/SteamLibrary")
        try write("""
        "libraryfolders"
        {
        	"0" { "path" "C:\\\\Program Files (x86)\\\\Steam" }
        	"1" { "path" "Z:\\\\\(extra.path.dropFirst().replacingOccurrences(of: "/", with: "\\\\"))" }
        }
        """, to: main.appendingPathComponent("libraryfolders.vdf"))
        try write(manifest(20, "beta Game", dir: "Beta"), to: main.appendingPathComponent("appmanifest_20.acf"))
        try write(manifest(228980, "Steamworks Common Redistributables", dir: "Steamworks Shared"),
                  to: main.appendingPathComponent("appmanifest_228980.acf"))
        try write(manifest(10, "Alpha", dir: "Alpha", flags: 1026), to: extra.appendingPathComponent("steamapps/appmanifest_10.acf"))
        try write("not vdf {", to: main.appendingPathComponent("appmanifest_99.acf"))

        let lib = SteamLibrary(paths: p)
        XCTAssertEqual(lib.libraryFolders().count, 2)
        let games = lib.games()
        XCTAssertEqual(games.map(\.name), ["Alpha", "beta Game"], "sorted, redistributables and broken files skipped")
        XCTAssertFalse(games[0].installed, "StateFlags without bit 4 is still downloading")
        XCTAssertTrue(games[1].installed)
        XCTAssertEqual(games[1].buildID, "100")
        XCTAssertEqual(games[0].installDir.path, extra.appendingPathComponent("steamapps/common/Alpha").path)
    }

    func testUnixPath() {
        let lib = SteamLibrary(paths: paths)
        XCTAssertEqual(lib.unixPath(#"Z:\Users\me\Games"#)?.path, "/Users/me/Games")
        XCTAssertEqual(lib.unixPath(#"z:\\Users\\me"#)?.path, "/Users/me")
        XCTAssertNil(lib.unixPath("relative"))
    }

    func testArtworkFindsNewCacheLayout() throws {
        let p = paths
        let cache = p.steamDir.appendingPathComponent("appcache/librarycache")
        try write("x", to: cache.appendingPathComponent("7/abc123/library_header.jpg"))
        XCTAssertEqual(SteamLibrary(paths: p).artwork(7)?.lastPathComponent, "library_header.jpg")
        XCTAssertNil(SteamLibrary(paths: p).artwork(7, portraitOnly: true))
        try write("x", to: cache.appendingPathComponent("7/def456/library_capsule.jpg"))
        XCTAssertEqual(SteamLibrary(paths: p).artwork(7)?.lastPathComponent, "library_capsule.jpg", "portrait preferred")
        XCTAssertEqual(SteamLibrary.artworkCDN(7).map(\.lastPathComponent), ["library_600x900_2x.jpg", "header.jpg"])
    }

    func testChangeStampMovesWhenManifestsChange() throws {
        let p = paths
        let main = p.steamDir.appendingPathComponent("steamapps")
        try write(manifest(1, "A", dir: "A"), to: main.appendingPathComponent("appmanifest_1.acf"))
        let lib = SteamLibrary(paths: p)
        let before = lib.changeStamp()
        let later = Date().addingTimeInterval(5)
        try write(manifest(2, "B", dir: "B"), to: main.appendingPathComponent("appmanifest_2.acf"))
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: main.appendingPathComponent("appmanifest_2.acf").path)
        XCTAssertGreaterThan(lib.changeStamp(), before)
    }
}
