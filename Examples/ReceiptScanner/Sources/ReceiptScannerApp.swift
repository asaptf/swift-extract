import Extract
import SwiftUI

@main
struct ReceiptScannerApp: App {
    @StateObject private var modelStore = ModelSettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(modelStore)
                #if os(macOS)
                    .frame(minWidth: 720, minHeight: 520)
                #endif
        }
        #if os(macOS)
            .defaultSize(width: 900, height: 640)
        #endif
    }
}
