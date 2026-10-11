import Foundation

/// Remembers RendererPolicy scans per game (games/<id>.scan.json) until Steam updates the
/// game, so listing the library or launching does not walk and parse game files each time.
public struct ScanCache: Sendable {
    /// Bump when detection logic changes so old results are recomputed.
    static let format = 3

    struct Entry: Codable {
        var format: Int
        var key: String
        var scan: RendererPolicy.Scan
    }

    public let paths: Paths
    public init(paths: Paths = .shared) { self.paths = paths }

    func url(_ id: Int) -> URL { paths.gameSettingsDir.appendingPathComponent("\(id).scan.json") }

    static func key(_ g: Game) -> String { "\(g.installDir.path)|\(g.buildID)|\(g.lastUpdated)" }

    public func scan(_ game: Game) -> RendererPolicy.Scan {
        let key = Self.key(game)
        if let data = try? Data(contentsOf: url(game.id)), let e = try? JSONDecoder().decode(Entry.self, from: data),
           e.format == Self.format, e.key == key, e.scan.mainExe.map({ $0.exists }) ?? true {
            return e.scan
        }
        let scan = RendererPolicy.scan(installDir: game.installDir)
        // Only cache complete installs that produced an answer; downloads change underneath.
        if game.installed, scan.mainExe != nil {
            try? FileManager.default.createDirectory(at: paths.gameSettingsDir, withIntermediateDirectories: true)
            try? JSON.encode(Entry(format: Self.format, key: key, scan: scan)).write(to: url(game.id), options: .atomic)
        }
        return scan
    }

    public func invalidate(_ id: Int) { try? FileManager.default.removeItem(at: url(id)) }
}
