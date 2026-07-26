import SwiftUI

struct ExtractingView: View {
    @State private var progress: CGFloat = 0
    @State private var step = 0

    private let steps = [
        "Reading document…",
        "Running OCR when needed…",
        "Building extraction schema…",
        "Asking the model…",
        "Validating typed result…",
    ]

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
                Text(steps[step % steps.count])
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut, value: step)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                progress = 0.85
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1100))
                step += 1
            }
        }
    }
}
