import Foundation

public enum CorpusDiscovery {
    public static let supportedExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp",
        "txt", "md",
    ]

    /// Enumerate supported document files under `root` (sorted, deterministic).
    public static func files(in root: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return isSupported(root) ? [root] : []
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard isSupported(url) else { continue }
            var regular: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &regular), !regular.boolValue {
                urls.append(url.standardizedFileURL)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Resolve corpus from `--corpus` flag or `EXTRACT_EVAL_CORPUS` env.
    public static func resolveCorpusPath(cliValue: String?) -> URL? {
        if let cliValue, !cliValue.isEmpty {
            return URL(fileURLWithPath: cliValue).standardizedFileURL
        }
        if let env = ProcessInfo.processInfo.environment["EXTRACT_EVAL_CORPUS"], !env.isEmpty {
            return URL(fileURLWithPath: env).standardizedFileURL
        }
        return nil
    }
}
