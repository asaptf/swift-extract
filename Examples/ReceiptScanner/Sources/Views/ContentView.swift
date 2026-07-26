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
                            onSettings: { showSettings = true }
                        )
                    case .extracting:
                        ExtractingView()
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
                            onUseMock: {
                                modelStore.backend = .mockDemo
                                phase = .pick
                            }
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

    private func runFile(_ url: URL) {
        guard modelStore.isConfigured else {
            errorMessage = modelStore.setupMessage
            phase = .setup
            return
        }
        phase = .extracting
        errorMessage = nil
        extractionTask?.cancel()
        extractionTask = Task {
            do {
                let session = try modelStore.makeSession()
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                let result: ExtractionResult<Receipt> = try await Extract.detailed(
                    from: .fileURL(url),
                    using: session
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(result.value)
                let raw = String(data: data, encoding: .utf8) ?? result.rawModelOutput
                await MainActor.run {
                    draft = ReceiptDraft(from: result.value, rawJSON: raw)
                    phase = .result
                }
            } catch let error as ExtractionError {
                await MainActor.run {
                    if case .modelUnavailable(let message) = error {
                        errorMessage = message
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    phase = .setup
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .setup
                }
            }
        }
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
