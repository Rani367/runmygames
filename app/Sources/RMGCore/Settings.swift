import Foundation

public enum Renderer: String, Codable, CaseIterable, Sendable {
    /// Apple D3DMetal (GPTK): DirectX 11 + 12, DXR, DLSS -> MetalFX.
    case d3dmetal
    /// DXMT: open-source DirectX 10/11 -> Metal. Usually the fastest DX11 path.
    case dxmt
    /// Wine's own WineD3D (OpenGL): DirectX 9 and older, DirectDraw.
    case wined3d

    public var title: String {
        switch self {
        case .d3dmetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .wined3d: return "WineD3D"
        }
    }
}

/// Global preferences (settings.json).
public struct GlobalSettings: Codable, Equatable, Sendable {
    public var metalHUD = false
    public var retinaMode = false
    public var msync = true
    /// Close Steam after the last game exits.
    public var quitSteamWhenIdle = true
    public var idleSeconds = 60
    /// Extra arguments for the Windows Steam client.
    public var steamArgs: [String] = []
    /// Look for a newer RunMyGames release on GitHub (at most once a day).
    public var checkForUpdates = true
    public var lastUpdateCheck: Date?

    public init() {}

    /// Missing keys keep their defaults, so settings files from older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlobalSettings()
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? d.metalHUD
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? d.retinaMode
        msync = try c.decodeIfPresent(Bool.self, forKey: .msync) ?? d.msync
        quitSteamWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .quitSteamWhenIdle) ?? d.quitSteamWhenIdle
        idleSeconds = try c.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? d.idleSeconds
        steamArgs = try c.decodeIfPresent([String].self, forKey: .steamArgs) ?? d.steamArgs
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
    }

    public static func load(_ paths: Paths = .shared) -> GlobalSettings {
        (try? JSON.decoder.decode(GlobalSettings.self, from: Data(contentsOf: paths.settingsFile))) ?? GlobalSettings()
    }

    public func save(_ paths: Paths = .shared) throws {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try JSON.encode(self).write(to: paths.settingsFile, options: .atomic)
    }
}

/// Per-game choices. `nil` means "automatic / use global default".
public struct GameSettings: Codable, Equatable, Sendable {
    public var renderer: Renderer?
    public var metalHUD: Bool?
    public var metalFX: Bool?
    public var retinaMode: Bool?
    /// Extra command line arguments for the game.
    public var args: String?
    public var env: [String: String]?
    /// Set when an automatically chosen renderer crashed early and we switched.
    public var autoFallback: Renderer?
    /// Renderers that already crashed on start, so automatic switching stops after one round.
    public var triedRenderers: [Renderer]?

    public init() {}

    /// Back to fully automatic renderer choice (also forgets crash history).
    public mutating func resetRenderer() {
        renderer = nil
        autoFallback = nil
        triedRenderers = nil
    }

    static func url(_ appID: Int, _ paths: Paths) -> URL {
        paths.gameSettingsDir.appendingPathComponent("\(appID).json")
    }

    public static func load(_ appID: Int, _ paths: Paths = .shared) -> GameSettings {
        (try? JSON.decoder.decode(GameSettings.self, from: Data(contentsOf: url(appID, paths)))) ?? GameSettings()
    }

    public func save(_ appID: Int, _ paths: Paths = .shared) throws {
        try FileManager.default.createDirectory(at: paths.gameSettingsDir, withIntermediateDirectories: true)
        try JSON.encode(self).write(to: Self.url(appID, paths), options: .atomic)
    }
}

/// Bundled known-good settings for specific games (compat/games.json).
public struct CompatEntry: Codable, Equatable, Sendable {
    public var name: String?
    public var renderer: Renderer?
    public var args: String?
    public var env: [String: String]?
    public var notes: String?

    public init(name: String? = nil, renderer: Renderer? = nil, args: String? = nil,
                env: [String: String]? = nil, notes: String? = nil) {
        self.name = name
        self.renderer = renderer
        self.args = args
        self.env = env
        self.notes = notes
    }
}

public enum CompatDB {
    public static func load(_ paths: Paths = .shared) -> [Int: CompatEntry] {
        guard let data = try? Data(contentsOf: paths.compatDB) else { return [:] }
        return (try? parse(data)) ?? [:]
    }

    /// Strict parse, used by CI to validate contributions to compat/games.json.
    public static func parse(_ data: Data) throws -> [Int: CompatEntry] {
        let raw = try JSONDecoder().decode([String: CompatEntry].self, from: data)
        var out: [Int: CompatEntry] = [:]
        for (k, v) in raw {
            guard let id = Int(k), id > 0 else { throw RMGError.failed("compat: \"\(k)\" is not a Steam app id") }
            out[id] = v
        }
        return out
    }
}

enum JSON {
    static func encode<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(v)
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
