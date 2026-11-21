import SwiftUI

struct FailureView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ScrollView {
            PageStatusCard(title: "", symbol: "wifi.exclamationmark", retry: retry)
                .padding(.horizontal, FloatingPageChrome.pageInset)
        }
        .existingFeedbackToast(message.isEmpty ? "暂时无法加载" : message)
    }
}
