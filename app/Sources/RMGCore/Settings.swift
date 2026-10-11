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

    public init() {}

    public static func load(_ paths: Paths = .shared) -> GlobalSettings {
        (try? JSONDecoder().decode(GlobalSettings.self, from: Data(contentsOf: paths.settingsFile))) ?? GlobalSettings()
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

    public init() {}

    static func url(_ appID: Int, _ paths: Paths) -> URL {
        paths.gameSettingsDir.appendingPathComponent("\(appID).json")
    }

    public static func load(_ appID: Int, _ paths: Paths = .shared) -> GameSettings {
        (try? JSONDecoder().decode(GameSettings.self, from: Data(contentsOf: url(appID, paths)))) ?? GameSettings()
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
}

public enum CompatDB {
    public static func load(_ paths: Paths = .shared) -> [Int: CompatEntry] {
        guard let data = try? Data(contentsOf: paths.compatDB),
              let raw = try? JSONDecoder().decode([String: CompatEntry].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }
}

enum JSON {
    static func encode<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(v)
    }
}
