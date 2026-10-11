import Foundation

/// Decides which graphics translation layer a game runs on, and builds the
/// per-game environment that rmgshim.exe applies.
public struct RendererPolicy: Sendable {
    public struct Decision: Equatable, Sendable {
        public var renderer: Renderer
        public var reason: String
        public var mainExe: URL?
        public var apis: Set<String>
        /// Arguments the chosen renderer needs (e.g. "-dx11" to keep a DX12-default
        /// Unreal game on its DX11 path when D3DMetal isn't available).
        public var args: [String] = []
        /// Unreal's bootstrap launcher next to the real game (e.g. Game.exe beside
        /// Game/Binaries/Win64/Game-Win64-Shipping.exe). Its prerequisite check fails
        /// under Wine, so the shim starts mainExe directly instead.
        public var unrealStub: String?
        /// Set when this launch switched away from a renderer that crashed on start.
        public var switchedFrom: Renderer?
    }

    /// What a look at the game's files found. Expensive (directory walk + PE parsing),
    /// so ScanCache keeps it until Steam updates the game.
    public struct Scan: Codable, Equatable, Sendable {
        public var mainExe: URL?
        public var apis: Set<String>
        public var unrealStub: String?

        public init(mainExe: URL?, apis: Set<String>, unrealStub: String?) {
            self.mainExe = mainExe
            self.apis = apis
            self.unrealStub = unrealStub
        }
    }

    public let paths: Paths
    public let d3dmetalAvailable: Bool
    public let dxmtAvailable: Bool

    public init(paths: Paths = .shared, d3dmetalAvailable: Bool, dxmtAvailable: Bool) {
        self.paths = paths
        self.d3dmetalAvailable = d3dmetalAvailable
        self.dxmtAvailable = dxmtAvailable
    }

    public init(engine: Engine) {
        self.init(paths: engine.paths, d3dmetalAvailable: engine.d3dmetalAvailable, dxmtAvailable: engine.dxmtAvailable)
    }

    // MARK: detection

    static let skipExe = ["unins", "crash", "redist", "setup", "vcredist", "vc_redist", "dxsetup", "dotnet",
                          "prereq", "easyanticheat", "battleye", "ue4prereq", "cefprocess", "helper", "report",
                          "updater", "install", "touchup", "uploader", "vconsole", "editor", "hammer", "crashpad",
                          "dedicated"]

    /// Best guess at the game's real executable.
    public static func mainExecutable(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return nil }
        var best: (url: URL, score: Int)?
        for case let u as URL in e {
            if e.level > 4 { e.skipDescendants(); continue }
            guard u.pathExtension.lowercased() == "exe" else { continue }
            let name = u.deletingPathExtension().lastPathComponent.lowercased()
            if skipExe.contains(where: name.contains) { continue }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var score = min(size / 1024, 200_000) - e.level * 10_000
            let siblings = u.deletingLastPathComponent()
            // Unity: Game.exe next to Game_Data/
            if fm.fileExists(atPath: siblings.appendingPathComponent(name + "_Data").path)
                || fm.fileExists(atPath: siblings.appendingPathComponent(u.deletingPathExtension().lastPathComponent + "_Data").path) {
                score += 500_000
            }
            // Unreal: Binaries/Win64/*-Shipping.exe
            if name.hasSuffix("-shipping") || name.contains("-win64-shipping") { score += 400_000 }
            if u.path.lowercased().contains("/binaries/win64/") { score += 50_000 }
            if best == nil || score > best!.score { best = (u, score) }
        }
        return best?.url
    }

    static let graphicsDLLs = ["d3d12.dll": "d3d12", "d3d11.dll": "d3d11", "d3d10.dll": "d3d10", "d3d10_1.dll": "d3d10",
                               "d3d9.dll": "d3d9", "d3d8.dll": "d3d8", "ddraw.dll": "ddraw", "opengl32.dll": "opengl",
                               "vulkan-1.dll": "vulkan", "dxgi.dll": "dxgi"]

    /// Renderer modules that engines load at runtime, found beside the exe (Source 2).
    static let rendererModules = ["rendersystemdx11.dll": "d3d11", "rendersystemvulkan.dll": "vulkan",
                                  "rendersystemdx9.dll": "d3d9"]

    /// Graphics APIs a game uses: imports of its exe plus engine DLLs beside it. Engines that
    /// load their renderer at runtime (Source 2, Godot, ...) import nothing graphical; for
    /// those, renderer modules beside the exe and DLL names inside it are the evidence.
    public static func graphicsAPIs(exe: URL) -> Set<String> {
        var imports = PEScanner.scan(exe)?.imports ?? []
        let dir = exe.deletingLastPathComponent()
        for dll in ["UnityPlayer.dll", "GameAssembly.dll", "Engine.dll", "renderer.dll", "Render.dll"] {
            if let i = PEScanner.scan(dir.appendingPathComponent(dll))?.imports { imports.formUnion(i) }
        }
        var apis = Set(imports.compactMap { graphicsDLLs[$0] })
        for (dll, api) in rendererModules where dir.appendingPathComponent(dll).exists { apis.insert(api) }
        if apis.isEmpty { apis = loadedByName(exe) }
        return apis
    }

    /// Graphics DLL names embedded in the exe (what LoadLibrary would be called with).
    static func loadedByName(_ exe: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: exe, options: .alwaysMapped) else { return [] }
        var out = Set<String>()
        for (dll, api) in graphicsDLLs where !out.contains(api) {
            let variants = Set([dll, dll.uppercased(), dll.prefix(1).uppercased() + dll.dropFirst(),
                                dll.replacingOccurrences(of: ".dll", with: "").uppercased() + ".dll"])
            if variants.contains(where: { data.range(of: Data($0.utf8)) != nil }) { out.insert(api) }
        }
        return out
    }

    // MARK: decision

    /// Small exe at the top of an Unreal game that only checks prerequisites and starts the shipping binary.
    public static func unrealStub(installDir: URL, mainExe: URL?) -> String? {
        guard let exe = mainExe, exe.path.lowercased().contains("/binaries/win64/"),
              exe.deletingPathExtension().lastPathComponent.lowercased().hasSuffix("-shipping") else { return nil }
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: installDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return top.first {
            let name = $0.deletingPathExtension().lastPathComponent.lowercased()
            return $0.pathExtension.lowercased() == "exe" && !skipExe.contains(where: name.contains)
                && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max) < 10 << 20
        }?.lastPathComponent
    }

    public static func scan(installDir: URL) -> Scan {
        let exe = mainExecutable(in: installDir)
        return Scan(mainExe: exe, apis: exe.map(graphicsAPIs) ?? [],
                    unrealStub: unrealStub(installDir: installDir, mainExe: exe))
    }

    /// `scan` defaults to a fresh look at the files; callers with a ScanCache pass its result.
    public func decide(game: Game, settings: GameSettings, compat: CompatEntry?, scan: Scan? = nil) -> Decision {
        let scan = scan ?? Self.scan(installDir: game.installDir)
        let exe = scan.mainExe, apis = scan.apis, stub = scan.unrealStub
        func pick(_ r: Renderer, _ why: String) -> Decision {
            Decision(renderer: available(r), reason: available(r) == r ? why : why + " (\(r.title) not installed)",
                     mainExe: exe, apis: apis, unrealStub: stub)
        }
        if let r = settings.renderer { return pick(r, "chosen in game settings") }
        if let r = compat?.renderer { return pick(r, "known-good setting from compatibility list") }
        if let r = settings.autoFallback { return pick(r, "switched after the previous renderer crashed") }

        let isUnreal = exe.map { $0.path.lowercased().contains("/binaries/win64/") } ?? false
        if apis.contains("d3d12") && (!apis.contains("d3d11") || isUnreal) {
            var d = pick(.d3dmetal, "game uses DirectX 12")
            if d.renderer == .dxmt && isUnreal && apis.contains("d3d11") {
                d.args = ["-dx11"]
                d.reason = "Unreal DirectX 12 game, running its DirectX 11 mode (import D3DMetal for DX12)"
            }
            return d
        }
        if apis.contains("d3d11") || apis.contains("d3d10") || apis.contains("dxgi") {
            return pick(.dxmt, "game uses DirectX 11")
        }
        if apis.contains("vulkan") {
            return pick(.dxmt, "game uses Vulkan, which runs on MoltenVK whatever is chosen here")
        }
        if !apis.isEmpty { return pick(.wined3d, "game uses \(apis.sorted().joined(separator: ", "))") }
        return pick(.dxmt, "graphics API not detected; DXMT is the safest fast default")
    }

    /// Falls back if the preferred renderer isn't installed.
    func available(_ r: Renderer) -> Renderer {
        switch r {
        case .d3dmetal where !d3dmetalAvailable: return dxmtAvailable ? .dxmt : .wined3d
        case .dxmt where !dxmtAvailable: return d3dmetalAvailable ? .d3dmetal : .wined3d
        default: return r
        }
    }

    /// Renderers to try, in order, when `r` crashes on start; skips ones not installed.
    public func fallbacks(after r: Renderer) -> [Renderer] {
        let order: [Renderer]
        switch r {
        case .dxmt: order = [.d3dmetal, .wined3d]
        case .d3dmetal: order = [.dxmt, .wined3d]
        case .wined3d: order = [.dxmt, .d3dmetal]
        }
        return order.filter { available($0) == $0 }
    }

    // MARK: environment

    public func environment(for d: Decision, settings: GameSettings, global: GlobalSettings,
                            compat: CompatEntry?) -> [String: String] {
        var env: [String: String] = [:]
        let metalFX = settings.metalFX ?? false
        switch d.renderer {
        case .dxmt:
            env["WINEDLLPATH_PREPEND"] = paths.dxmt.path
            env["WINEDLLOVERRIDES"] = "d3d11,d3d10core,dxgi,winemetal=b"
            env["DXMT_ENABLE_NVEXT"] = "1"            // NVAPI/NGX -> MetalFX for DLSS titles
            if metalFX { env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1" }
            env["CX_ACTIVE_GRAPHICS_BACKEND"] = "dxmt"
        case .d3dmetal:
            env["WINEDLLPATH_PREPEND"] = paths.d3dmetal.appendingPathComponent("wine").path
            env["WINEDLLOVERRIDES"] = "d3d11,d3d12,dxgi,nvapi64,nvngx,atidxx64=b"
            env["CX_ACTIVE_GRAPHICS_BACKEND"] = "d3dmetal"
            env["D3DM_SUPPORT_DXR"] = "1"               // hardware ray tracing (M3 and newer)
            if metalFX { env["D3DM_ENABLE_METALFX"] = "1" } // DLSS -> MetalFX
        case .wined3d:
            env["CX_ACTIVE_GRAPHICS_BACKEND"] = "wined3d"
        }
        if let stub = d.unrealStub, let exe = d.mainExe, let win = paths.windowsPath(exe) {
            env["RMG_REPLACE"] = stub
            env["RMG_EXEC"] = win
        }
        if settings.metalHUD ?? global.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        compat?.env?.forEach { env[$0] = $1 }
        settings.env?.forEach { env[$0] = $1 }
        let args = ([d.args.joined(separator: " ")] + [compat?.args, settings.args].compactMap { $0 })
            .filter { !$0.isEmpty }.joined(separator: " ")
        if !args.isEmpty { env["RMG_ARGS"] = args }
        return env
    }
}
