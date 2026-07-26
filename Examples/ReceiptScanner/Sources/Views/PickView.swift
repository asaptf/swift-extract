import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#endif

struct PickView: View {
    var onFixture: (SampleFixture) -> Void
    var onImport: () -> Void
    var onPhotoData: (Data) -> Void
    var onSettings: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                importCard
                captureRow
                fixturesSection
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    onPhotoData(data)
                }
            }
        }
        #if os(iOS)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in
                    showCamera = false
                    if let data {
                        onPhotoData(data)
                    }
                }
                .ignoresSafeArea()
            }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extract structure from anything")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text(
                "Drop a PDF, take a photo, or pick a screenshot. Define a Swift type once — get a validated instance back."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importCard: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])
                    )
                    .foregroundStyle(.orange.opacity(0.7))
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("Drop a PDF or image")
                        .font(.headline)
                    Text("or choose a file from disk")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(action: onImport) {
                        Label("Choose File", systemImage: "folder")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                }
                .padding(32)
            }
            .frame(minHeight: 200)
        }
    }

    private var captureRow: some View {
        HStack(spacing: 12) {
            PhotosPicker(
                selection: $photoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Photo Library", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            #if os(iOS)
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            #else
                // macOS: PhotosPicker covers Continuity Camera / library; file importer handles drop.
                Button(action: onImport) {
                    Label("Scan / Import", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            #endif
        }
    }

    private var fixturesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try a sample")
                .font(.title3.weight(.semibold))
            Text(
                "Bundled fixtures exercise the real extraction pipeline. Configure a model in Settings first (Apple Intelligence, OpenAI, Anthropic, or MLX)."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(SampleFixture.allCases) { fixture in
                Button {
                    onFixture(fixture)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: fixture.systemImage)
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fixture.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(fixture.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.background.secondary)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#if os(iOS)
    /// UIKit camera wrapper for take-a-photo on iOS.
    struct CameraPicker: UIViewControllerRepresentable {
        var onFinish: (Data?) -> Void

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onFinish: onFinish)
        }

        final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let onFinish: (Data?) -> Void
            init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                onFinish(nil)
            }

            func imagePickerController(
                _ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                let image = (info[.originalImage] as? UIImage)
                onFinish(image?.jpegData(compressionQuality: 0.9))
            }
        }
    }
#endif
