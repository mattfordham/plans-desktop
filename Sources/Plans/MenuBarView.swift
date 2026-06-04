import SwiftUI

/// Surface A content: the menu bar item's drop-down menu.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Browser") {
            openWindow(id: "browser")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
