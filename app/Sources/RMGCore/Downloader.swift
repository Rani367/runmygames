import CryptoKit
import Foundation

/// Fraction done (0...1), or nil while the size is unknown.
public typealias DownloadProgress = @Sendable (Double?) -> Void

/// File downloads with progress, HTTP status checks and optional SHA-256 verification.
public enum Downloader {
    /// Downloads `url` to `dest` (replacing it). `file://` URLs are copied, which tests
    /// and offline installs use.
    public static func fetch(_ url: URL, to dest: URL, sha256: String? = nil,
                             progress: DownloadProgress? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        if url.isFileURL {
            try fm.copyItem(at: url, to: part)
        } else {
            let tmp = try await DownloadTask(url: url, progress: progress).run()
            try fm.moveItem(at: tmp, to: part)
        }
        if let sha256 {
            let got = try Self.sha256(of: part)
            guard got.caseInsensitiveCompare(sha256) == .orderedSame else {
                try? fm.removeItem(at: part)
                throw RMGError.failed("Checksum mismatch for \(url.lastPathComponent) (expected \(sha256), got \(got)).")
            }
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
        progress?(1)
    }

    /// Small payloads (JSON, artwork). Throws on non-2xx.
    public static func data(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("RunMyGames/\(Version.current)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, url)
        return data
    }

    public static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func check(_ resp: URLResponse?, _ url: URL) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw RMGError.failed("Download failed: \(url.host ?? url.absoluteString) answered HTTP \(http.statusCode) for \(url.lastPathComponent).")
        }
    }
}

/// One URLSession download task bridged to async/await with byte-level progress.
private final class DownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let url: URL
    let progress: DownloadProgress?
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastPercent = -1
    private let lock = NSLock()

    init(url: URL, progress: DownloadProgress?) {
        self.url = url
        self.progress = progress
    }

    func run() async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            lock.withLock { continuation = c }
            var req = URLRequest(url: url)
            req.setValue("RunMyGames/\(Version.current)", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: req).resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let c: CheckedContinuation<URL, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        guard let progress else { return }
        guard total > 0 else { return progress(nil) }
        // At most one callback per percent: UI updates hop to the main thread.
        let percent = Int(written * 100 / total)
        let report: Bool = lock.withLock {
            defer { lastPercent = percent }
            return percent != lastPercent
        }
        if report { progress(Double(written) / Double(total)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try Downloader.check(downloadTask.response, url)
            // `location` is deleted when this method returns: move it somewhere stable first.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent("rmg-dl-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: keep)
            finish(.success(keep))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
