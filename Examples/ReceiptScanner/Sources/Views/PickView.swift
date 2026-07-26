import SwiftUI

struct PickView: View {
    var onFixture: (SampleFixture) -> Void
    var onImport: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                importCard
                fixturesSection
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extract structure from anything")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text(
                "Drop a PDF, photo, or screenshot. Define a Swift type once — get a validated instance back."
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

    private var fixturesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try a sample")
                .font(.title3.weight(.semibold))
            Text("Works offline with Demo mock — no API key required.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
