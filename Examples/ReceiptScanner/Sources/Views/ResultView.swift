import SwiftUI

struct ResultView: View {
    @Binding var draft: ReceiptDraft
    @Binding var showRawJSON: Bool
    var onReset: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("Extraction complete", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Spacer()
                    Toggle("Raw JSON", isOn: $showRawJSON)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Text("Raw JSON")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if showRawJSON {
                    rawJSONCard
                } else {
                    formCard
                }

                Button(action: onReset) {
                    Label("Extract another", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                labeledField("Merchant") {
                    TextField("Merchant", text: $draft.merchant)
                }
                labeledField("Date") {
                    DatePicker("", selection: $draft.date, displayedComponents: .date)
                        .labelsHidden()
                }
                HStack(spacing: 12) {
                    labeledField("Total") {
                        TextField("0.00", text: $draft.total)
                            #if os(iOS)
                                .keyboardType(.decimalPad)
                            #endif
                    }
                    labeledField("Currency") {
                        TextField("USD", text: $draft.currency)
                            .frame(width: 80)
                    }
                }
            }

            Divider()

            Text("Line items")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach($draft.items) { $item in
                HStack(spacing: 8) {
                    TextField("Name", text: $item.name)
                    TextField("Price", text: $item.price)
                        .frame(width: 80)
                    TextField("Qty", text: $item.quantity)
                        .frame(width: 48)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            if draft.items.isEmpty {
                Text("No line items extracted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        )
        .textFieldStyle(.plain)
    }

    private var rawJSONCard: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(draft.rawJSON)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func labeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
        }
    }
}
