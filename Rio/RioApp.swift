import AppKit
import SwiftUI

@main
struct RioApp: App {
    @StateObject private var sessionController: LiveSessionController
    @StateObject private var resourceFolderController: LocalResourceFolderController

    init() {
        _sessionController = StateObject(
            wrappedValue: RioCompositionRoot.makeLiveController()
        )
        _resourceFolderController = StateObject(
            wrappedValue: LocalResourceFolderController()
        )
    }

    var body: some Scene {
        WindowGroup("Rio", id: "main") {
            RioView(
                controller: sessionController,
                resourceFolderController: resourceFolderController
            )
        }
        .defaultSize(width: 560, height: 620)

        MenuBarExtra("Rio", systemImage: "waveform") {
            RioMenuBarMenu(controller: sessionController)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct RioMenuBarMenu<Controller: SessionShellControlling>: View {
    @ObservedObject private var controller: Controller
    @Environment(\.openWindow) private var openWindow

    init(controller: Controller) {
        self.controller = controller
    }

    var body: some View {
        Button {
            Task { await controller.performPrimaryAction() }
        } label: {
            Label(
                controller.primaryActionTitle,
                systemImage: controller.status == .listening || controller.status == .processing
                    ? "stop.fill"
                    : "record.circle"
            )
        }
        .disabled(
            controller.isPerformingPrimaryAction || controller.status == .checkingAvailability
        )

        Divider()

        Button("Open Rio") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit Rio") {
            NSApplication.shared.terminate(nil)
        }
    }
}
