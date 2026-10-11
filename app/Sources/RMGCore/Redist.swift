import Foundation

/// Windows runtimes most games expect (CrossOver preinstalls the same into its Steam bottles).
public enum Redist {
    public struct Package: Sendable {
        public let name: String
        public let url: URL
        public let file: String
        public let args: [String]
        /// Registry key Microsoft's installer writes ("Installed"=1); games check it.
        public let regKey: String
    }

    public static let all: [Package] = [
        Package(name: "Visual C++ 2015–2022 (x64)",
                url: URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!,
                file: "vc_redist.x64.exe", args: ["/install", "/quiet", "/norestart"],
                regKey: #"HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"#),
        Package(name: "Visual C++ 2015–2022 (x86)",
                url: URL(string: "https://aka.ms/vs/17/release/vc_redist.x86.exe")!,
                file: "vc_redist.x86.exe", args: ["/install", "/quiet", "/norestart"],
                regKey: #"HKLM\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86"#),
    ]

    /// Installs any missing packages; skips ones already present.
    public static func installMissing(engine: Engine, force: Bool = false,
                                      progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let paths = engine.paths
        let dir = paths.rmgWin.appendingPathComponent("redist")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Wine ships builtin stand-ins for the runtime DLLs, so file checks are useless;
        // games look at the registry key Microsoft's installer writes.
        for p in all where force || !installed(p, engine) {
            progress("Downloading \(p.name)…")
            let dest = dir.appendingPathComponent(p.file)
            if !dest.exists {
                let name = p.name
                try await Downloader.fetch(p.url, to: dest) { f in
                    if let f { progress("Downloading \(name)… \(Int(f * 100))%") }
                }
            }
            progress("Installing \(p.name)…")
            // Burn's exit code does not survive Wine's process plumbing reliably; trust the registry.
            try engine.run([dest.path] + p.args, log: paths.logs.appendingPathComponent("redist.log"))
            guard installed(p, engine) else {
                // A corrupt cached installer would fail the same way forever.
                try? FileManager.default.removeItem(at: dest)
                throw RMGError.failed("\(p.name) did not install. Details: ~/Library/Logs/RunMyGames/redist.log")
            }
        }
    }

    /// Asks the live registry (works while Steam is running, unlike reading system.reg).
    static func installed(_ p: Package, _ engine: Engine) -> Bool {
        (try? engine.run(["reg", "query", p.regKey, "/v", "Installed"]).terminationStatus) == 0
    }
}
