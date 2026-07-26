import SwiftUI

struct ExtractingView: View {
    /// Live status from the extraction pipeline (OCR, model, validation…).
    var status: String
    /// Wall-clock seconds since extraction started.
    var elapsedSeconds: Int
    var onCancel: () -> Void

    @State private var progress: CGFloat = 0

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.15), lineWidth: 8)
                    .frame(width: 120, height: 120)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: [.orange, .pink, .orange],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.orange)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }

            VStack(spacing: 8) {
                Text("Extracting")
                    .font(.title2.weight(.semibold))
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: status)
                    .frame(maxWidth: 320)
                Text(elapsedLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                progress = 0.85
            }
        }
    }

    private var elapsedLabel: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        if m > 0 {
            return String(format: "%d:%02d elapsed", m, s)
        }
        return "\(elapsedSeconds)s elapsed"
    }
}
