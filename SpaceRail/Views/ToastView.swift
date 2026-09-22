import Observation
import SwiftUI

@Observable
final class ToastModel {
    var feedback: Feedback?
}

// One line, one symbol. Appears instantly (it answers a keystroke) and fades when it has been read.
struct ToastView: View {
    let model: ToastModel

    var body: some View {
        if let feedback = model.feedback {
            HStack(spacing: 10) {
                Image(systemName: feedback.symbol)
                    .font(.title3)
                    .foregroundStyle(feedback.isRefusal ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                Text(feedback.message)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
        }
    }
}
