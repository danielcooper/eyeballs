import SwiftUI

struct DiffPaneView: NSViewControllerRepresentable {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState
    /// Read by the parent's body, so SwiftUI updates the pane whenever the layer, or its place
    /// in the stack, changes.
    let layer: LayerContent?
    let layerItem: LayerItem?
    let stack: StackItem?

    func makeNSViewController(context: Context) -> DiffPaneController {
        let controller = DiffPaneController(model: model, windowState: windowState)
        windowState.pane = controller
        controller.scheduleRefresh()
        return controller
    }

    func updateNSViewController(_ controller: DiffPaneController, context: Context) {
        controller.scheduleRefresh()
    }
}
