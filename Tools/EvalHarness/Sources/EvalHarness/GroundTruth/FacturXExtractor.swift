import Foundation

/// Extract embedded Factur-X / ZUGFeRD CII XML from a PDF.
///
/// Uses `mutool extract` (preferred; works on this project's machines). Falls back to
/// `pdfdetach` when mutool is missing. No network, no Python PDF libraries.
public enum FacturXExtractor {
    public enum ExtractError: Error, CustomStringConvertible {
        case toolFailed(String)
        case noEmbeddedXML
        case unreadableXML(String)

        public var description: String {
            switch self {
            case .toolFailed(let m): return m
            case .noEmbeddedXML: return "No embedded Factur-X / ZUGFeRD XML attachment found"
            case .unreadableXML(let m): return "Could not read embedded XML: \(m)"
            }
        }
    }

    /// Extract and parse ground truth from a PDF. Returns `nil` when the file has no
    /// embedded CII XML (not an error — most plain PDFs are in this category).
    public static func groundTruth(fromPDF url: URL) throws -> InvoiceGroundTruth? {
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        guard let xmlData = try extractXMLData(from: url) else { return nil }
        return try CIIParser.parse(xmlData)
    }

    /// Returns raw XML bytes when present.
    public static func extractXMLData(from url: URL) throws -> Data? {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
            .appendingPathComponent("extract-eval-fx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        if which("mutool") != nil {
            if let data = try extractWithMutool(pdf: url, workDir: temp) {
                return data
            }
        }
        if which("pdfdetach") != nil {
            if let data = try extractWithPdfdetach(pdf: url, workDir: temp) {
                return data
            }
        }
        // No tool succeeded in finding XML — treat as absent, not a hard error.
        // If mutool ran and only fonts came out, the PDF simply has no attachment.
        return nil
    }

    // MARK: - mutool

    private static func extractWithMutool(pdf: URL, workDir: URL) throws -> Data? {
        let result = try run(
            "/usr/bin/env",
            arguments: ["mutool", "extract", pdf.path],
            cwd: workDir
        )
        if result.exitCode != 0 {
            // mutool may still have written files; only fail hard on missing binary.
            if result.stderr.contains("No such file") || result.stderr.contains("not found") {
                throw ExtractError.toolFailed("mutool extract failed: \(result.stderr)")
            }
        }
        return firstCIIXML(in: workDir)
    }

    // MARK: - pdfdetach (fallback)

    private static func extractWithPdfdetach(pdf: URL, workDir: URL) throws -> Data? {
        let list = try run(
            "/usr/bin/env",
            arguments: ["pdfdetach", "-list", pdf.path],
            cwd: workDir
        )
        guard list.exitCode == 0 else { return nil }
        // "1: factur-x.xml" lines
        let lines = list.stdout.split(separator: "\n").map(String.init)
        var index: Int?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let numPart = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let name = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let n = Int(numPart) else { continue }
            if name.contains("factur") || name.contains("zugferd") || name.hasSuffix(".xml") {
                index = n
                break
            }
            if index == nil { index = n }
        }
        guard let index else { return nil }
        let out = workDir.appendingPathComponent("attachment-\(index).xml")
        let save = try run(
            "/usr/bin/env",
            arguments: ["pdfdetach", "-save", "\(index)", "-o", out.path, pdf.path],
            cwd: workDir
        )
        guard save.exitCode == 0, FileManager.default.fileExists(atPath: out.path) else {
            return nil
        }
        return try Data(contentsOf: out)
    }

    // MARK: - helpers

    private static func firstCIIXML(in directory: URL) -> Data? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let preferredNames = ["factur-x.xml", "zugferd-invoice.xml", "zugferd.xml", "xrechnung.xml"]
        let xmlFiles = items.filter { $0.pathExtension.lowercased() == "xml" }
        // Prefer known Factur-X attachment names, then any XML that looks like CII.
        let ordered =
            xmlFiles.sorted { a, b in
                let an = a.lastPathComponent.lowercased()
                let bn = b.lastPathComponent.lowercased()
                let ap = preferredNames.firstIndex(of: an) ?? 999
                let bp = preferredNames.firstIndex(of: bn) ?? 999
                if ap != bp { return ap < bp }
                return an < bn
            }

        for file in ordered {
            guard let data = try? Data(contentsOf: file) else { continue }
            if looksLikeCII(data) { return data }
        }
        // mutool names attachments `file-NNNN.xml` — accept first CII-looking stream.
        for file in items where file.pathExtension.lowercased() == "xml" {
            guard let data = try? Data(contentsOf: file), looksLikeCII(data) else { continue }
            return data
        }
        return nil
    }

    private static func looksLikeCII(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        return s.contains("CrossIndustryInvoice")
            || s.contains("CrossIndustryDocument")
            || s.contains("rsm:CrossIndustryInvoice")
    }

    private static func which(_ name: String) -> String? {
        let r = try? run("/usr/bin/env", arguments: ["which", name], cwd: FileManager.default.temporaryDirectory)
        guard let r, r.exitCode == 0 else { return nil }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private struct ProcessResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private static func run(
        _ launchPath: String,
        arguments: [String],
        cwd: URL
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
