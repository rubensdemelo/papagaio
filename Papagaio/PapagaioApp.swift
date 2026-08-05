import SwiftUI

@main
struct PapagaioApp: App {
    @StateObject private var sessionController: LiveSessionController

    init() {
        _sessionController = StateObject(
            wrappedValue: PapagaioCompositionRoot.makeLiveController()
        )
    }

    var body: some Scene {
        WindowGroup {
            PapagaioView(controller: sessionController)
        }
        .defaultSize(width: 560, height: 620)
    }
}
