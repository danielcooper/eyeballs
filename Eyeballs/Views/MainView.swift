import SwiftUI

struct MainView: View {
    var body: some View {
        ContentUnavailableView(
            "Nothing to review yet",
            systemImage: "eyes",
            description: Text("When an agent opens a stack for review, it appears here."))
            .frame(minWidth: 600, minHeight: 400)
    }
}
