import SwiftUI

@main
struct PapagaioApp: App {
    @StateObject private var sessionController: LiveSessionController
    @StateObject private var resourceFolderController: LocalResourceFolderController

    init() {
        _sessionController = StateObject(
            wrappedValue: PapagaioCompositionRoot.makeLiveController()
        )
        _resourceFolderController = StateObject(
            wrappedValue: LocalResourceFolderController()
        )
    }

    var body: some Scene {
        WindowGroup {
            PapagaioView(
                controller: sessionController,
                resourceFolderController: resourceFolderController
            )
        }
        .defaultSize(width: 560, height: 620)
    }
}
