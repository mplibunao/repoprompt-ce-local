import SwiftUI

/// The window's stuck MCP call notice: the recovery notice or the exhaustion warning.
/// Observes the per-window MCP model directly so a settlement recovery redraws
/// without depending on an unrelated `ContentViewModel` publication.
struct CodeStructureSettlementLimitNoticeBanner: View {
    @ObservedObject var server: MCPServerViewModel

    var body: some View {
        if let notice = server.codeStructureSettlementLimitNotice {
            let tint: Color = notice.isWarning ? .orange : .blue
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : "arrow.clockwise.circle.fill")
                    .foregroundStyle(tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.headline)
                    Text(notice.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: 720, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(0.5), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(notice.title). \(notice.message)")
        }
    }
}
