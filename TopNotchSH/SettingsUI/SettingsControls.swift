import SwiftUI

/// Labeled slider with a live value readout.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0.rounded()))" }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

extension SliderRow {
    static func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }
    static func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }
    static func fraction(_ value: Double) -> String { String(format: "%.2f", value) }
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// Secondary explanatory text under a control.
struct Caption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Three sliders for the inset around the terminal.
struct InsetsEditor: View {
    @Binding var insets: ContentInsets

    var body: some View {
        SliderRow(title: "Top", value: $insets.top, range: 0...40, format: SliderRow.points)
        SliderRow(title: "Sides", value: $insets.horizontal, range: 0...40, format: SliderRow.points)
        SliderRow(title: "Bottom", value: $insets.bottom, range: 0...40, format: SliderRow.points)
    }
}
