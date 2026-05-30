import Combine
import Foundation

// AppState is the observable model shared by the SwiftUI settings window and the
// AppKit menu bar / HUD. It is updated from IPC events on the main queue.
final class AppState: ObservableObject {
    @Published var view: ViewState = .idle
    @Published var levels: Levels = Levels(current: 0, session: 0)
    @Published var permissions: Permissions = Permissions(accessibility: false, microphone: false)
    @Published var modelProgress: ModelProgress?

    func apply(_ event: IncomingEvent) {
        switch event {
        case .state(let state):
            view = state
        case .levels(let levels):
            self.levels = levels
        case .permissions(let permissions):
            // Accessibility is owned by the frontend (AccessibilityManager); the
            // backend only knows the microphone state.
            self.permissions.microphone = permissions.microphone
        case .modelProgress(let progress):
            modelProgress = progress
        case .insertText:
            // Handled by AppDelegate, which performs the native paste.
            break
        }
    }
}
