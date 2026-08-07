import SwiftUI

@main
struct CopoolApp: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) var statusBarController

    var body: some Scene {
        Settings { EmptyView() }
    }
}
