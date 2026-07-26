import Extract
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

struct ContentView: View {
    @EnvironmentObject private var modelStore: ModelSettingsStore
    @State private var phase: AppPhase = .pick
    @State private var draft = ReceiptDraft.empty
    @State private var showRawJSON = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var extractionTask: Task<Void, Never>?
    @State private var extractionStatus = "Starting…"
    @State private var extractionElapsed = 0
    @State private var elapsedTicker: Task<Void, Never>?

    /// Hard ceiling so a hung model / network cannot pin the UI forever.
    private static let extractionTimeout: Duration = .seconds(180)

    enum AppPhase: Equatable {
        case pick
        case extracting
        case result
        case setup
    }

    var body: some View {
        NavigationStack {
            ZStack {
                background
                Group {
                    switch phase {
                    case .pick:
                        PickView(
                            onFixture: { runFixture($0) },
                            onImport: { showImporter = true },
                            onPhotoData: { runImageData($0) },
                            onSettings: { showSettings = true }
                        )
                    case .extracting:
                        ExtractingView(
                            status: extractionStatus,
                            elapsedSeconds: extractionElapsed,
                            onCancel: cancelExtraction
                        )
                    case .result:
                        ResultView(
                            draft: $draft,
                            showRawJSON: $showRawJSON,
                            onReset: { phase = .pick }
                        )
                    case .setup:
                        SetupView(
                            message: errorMessage ?? modelStore.setupMessage,
                            onSettings: { showSettings = true },
                            onDismiss: { phase = .pick }
                        )
                    }
                }
            }
            .navigationTitle("Receipt Scanner")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(modelStore)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.pdf, .image, .png, .jpeg, .heic],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    runFile(url)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    phase = .setup
                }
            }
            .onAppear {
                // Surface setup immediately when no backend is ready (no fake happy path).
                if !modelStore.isConfigured, phase == .pick {
                    // Stay on pick so user can open Settings; fixtures will route to setup.
                }
            }
            .onDisappear {
                cancelExtraction()
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.orange.opacity(0.18),
                Color.pink.opacity(0.10),
                Color.windowBackgroundColorCompat,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func runFixture(_ fixture: SampleFixture) {
        guard let url = fixture.url else {
            errorMessage = "Fixture \(fixture.title) is missing from the app bundle."
            phase = .setup
            return
        }
        runFile(url)
    }

    private func runImageData(_ data: Data) {
        guard modelStore.isConfigured else {
            errorMessage = modelStore.setupMessage
            phase = .setup
            return
        }
        let modelStatus = statusForBackend()
        beginExtraction()
        extractionTask = Task {
            do {
                let session = try await makeSessionOffMain()
                setStatus("Preparing image…")
                let source = try ExtractionSource.image(data: data)
                try await runExtraction(
                    source: source,
                    session: session,
                    modelStatus: modelStatus
                )
            } catch is CancellationError {
                await returnToPickIfStillExtracting()
            } catch {
                await presentError(error)
            }
        }
    }

    private func runFile(_ url: URL) {
        guard modelStore.isConfigured else {
            errorMessage = modelStore.setupMessage
            phase = .setup
            return
        }
        let modelStatus = statusForBackend()
        beginExtraction()
        extractionTask = Task {
            do {
                let session = try await makeSessionOffMain()
                setStatus("Reading file…")

                // Copy security-scoped bytes up front so the rest of the pipeline
                // does not depend on a long-lived sandbox bookmark (avoids LS/xpc noise
                // and "process may not map database" during long model calls).
                let source = try await loadSourceFromFile(url)
                try await runExtraction(
                    source: source,
                    session: session,
                    modelStatus: modelStatus
                )
            } catch is CancellationError {
                await returnToPickIfStillExtracting()
            } catch {
                await presentError(error)
            }
        }
    }

    private func beginExtraction() {
        extractionTask?.cancel()
        elapsedTicker?.cancel()
        errorMessage = nil
        extractionStatus = "Starting…"
        extractionElapsed = 0
        phase = .extracting
        elapsedTicker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if phase == .extracting {
                        extractionElapsed += 1
                    }
                }
            }
        }
    }

    private func cancelExtraction() {
        extractionTask?.cancel()
        extractionTask = nil
        elapsedTicker?.cancel()
        elapsedTicker = nil
        if phase == .extracting {
            phase = .pick
        }
    }

    /// Build the session on the main actor (ModelSettingsStore), then hop off for work.
    private func makeSessionOffMain() async throws -> ExtractionSession {
        setStatus("Configuring model…")
        return try await MainActor.run {
            try modelStore.makeSession()
        }
    }

    private func loadSourceFromFile(_ url: URL) async throws -> ExtractionSource {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            // Prefer reading into memory / temp so security scope can end immediately.
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"].contains(ext)
                || (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
            {
                let data = try Data(contentsOf: url)
                return try ExtractionSource.image(data: data)
            }

            // PDF / text: copy into a temporary file the app owns.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("receipt-import-\(UUID().uuidString)")
                .appendingPathExtension(url.pathExtension.isEmpty ? "bin" : url.pathExtension)
            if FileManager.default.fileExists(atPath: temp.path) {
                try FileManager.default.removeItem(at: temp)
            }
            try FileManager.default.copyItem(at: url, to: temp)
            return .fileURL(temp)
        }.value
    }

    private func runExtraction(
        source: ExtractionSource,
        session: ExtractionSession,
        modelStatus: String
    ) async throws {
        try Task.checkCancellation()
        setStatus("Reading document / OCR…")

        // Give the UI a beat to paint status before potentially long OCR.
        try await Task.sleep(for: .milliseconds(50))
        try Task.checkCancellation()
        setStatus(modelStatus)

        let timeoutSeconds = Int(Self.extractionTimeout.components.seconds)
        let result: ExtractionResult<Receipt> = try await withThrowingTaskGroup(
            of: ExtractionResult<Receipt>.self
        ) { group in
            group.addTask {
                // Keep generation off the cooperative main-actor path as much as possible.
                try await Extract.detailed(from: source, using: session)
            }
            group.addTask {
                try await Task.sleep(for: Self.extractionTimeout)
                throw ExtractionTimeoutError(seconds: timeoutSeconds)
            }
            guard let first = try await group.next() else {
                throw ExtractionError.internalError("Extraction produced no result.")
            }
            group.cancelAll()
            return first
        }

        try Task.checkCancellation()
        setStatus("Decoding result…")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result.value)
        let raw = String(data: data, encoding: .utf8) ?? result.rawModelOutput

        await MainActor.run {
            elapsedTicker?.cancel()
            elapsedTicker = nil
            draft = ReceiptDraft(from: result.value, rawJSON: raw)
            phase = .result
        }
    }

    @MainActor
    private func statusForBackend() -> String {
        switch modelStore.backend {
        case .mlx:
            if modelStore.mlxIsOnDisk {
                return "Running local MLX model (first load can take a minute)…"
            }
            return "Downloading / loading MLX model, then generating…"
        case .appleIntelligence:
            return "Asking Apple Intelligence…"
        case .openAI:
            return "Calling OpenAI…"
        case .anthropic:
            return "Calling Anthropic…"
        }
    }

    private func setStatus(_ text: String) {
        Task { @MainActor in
            extractionStatus = text
        }
    }

    private func returnToPickIfStillExtracting() async {
        await MainActor.run {
            elapsedTicker?.cancel()
            elapsedTicker = nil
            if phase == .extracting {
                phase = .pick
            }
        }
    }

    private func presentError(_ error: Error) async {
        await MainActor.run {
            elapsedTicker?.cancel()
            elapsedTicker = nil
            if let timeout = error as? ExtractionTimeoutError {
                errorMessage = timeout.localizedDescription
            } else if let extraction = error as? ExtractionError {
                switch extraction {
                case .modelUnavailable(let message):
                    errorMessage = message
                case .validationFailed(let attempts, let lastError, let raw):
                    let preview = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    let snippet = preview.count > 280 ? String(preview.prefix(280)) + "…" : preview
                    errorMessage = """
                        Validation failed after \(attempts) attempt(s): \
                        \(lastError.localizedDescription)

                        Model output preview:
                        \(snippet.isEmpty ? "(empty)" : snippet)
                        """
                default:
                    errorMessage = extraction.localizedDescription
                }
            } else {
                errorMessage = error.localizedDescription
            }
            phase = .setup
        }
    }
}

// MARK: - Timeout

private struct ExtractionTimeoutError: Error, LocalizedError {
    let seconds: Int
    var errorDescription: String? {
        """
        Extraction timed out after \(seconds)s. The model may still be downloading, \
        overloaded, or unreachable. Check Settings (backend / API key / MLX download), \
        then try a smaller fixture or model.
        """
    }
}

// MARK: - Color helpers

extension Color {
    static var windowBackgroundColorCompat: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }
}
