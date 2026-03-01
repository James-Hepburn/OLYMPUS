import SwiftUI
import FirebaseCore

// MARK: - OLYMPUSApp
/// The application entry point, marked with `@main` to designate it as the
/// top-level Swift entry point that replaces the traditional `UIApplicationMain`.
///
/// Responsibilities:
/// - Configure Firebase before any view is rendered.
/// - Display `LaunchScreenView` for a fixed duration on first launch.
/// - Transition to `ContentView` (the main menu) once the splash period ends.
@main
struct OLYMPUSApp: App {

    // MARK: State

    /// Controls whether the splash screen or the main menu is shown.
    /// Starts `true` and is flipped to `false` after the launch delay, which
    /// triggers the `.easeInOut` transition to `ContentView`.
    @State private var isLoading = true

    // MARK: Initialiser

    /// Configures Firebase before the first view renders.
    ///
    /// `FirebaseApp.configure()` must be called exactly once, as early as
    /// possible in the app lifecycle — the `App` initialiser is the correct
    /// place because it runs before `body` is evaluated and therefore before
    /// any view that might use Firebase (e.g. `MultiplayerManager`) is created.
    init () {
        FirebaseApp.configure ()
    }

    // MARK: Scene

    var body: some Scene {
        WindowGroup {
            if isLoading {
                // MARK: Launch Screen
                // `LaunchScreenView` is shown for 5 seconds then replaced by
                // `ContentView`. The delay is driven by a `DispatchQueue` timer
                // rather than a SwiftUI animation because the duration must be
                // fixed regardless of frame timing or animation curves.
                LaunchScreenView ()
                    .onAppear {
                        DispatchQueue.main.asyncAfter (deadline: .now () + 5) {
                            // `.easeInOut` produces a smooth cross-dissolve between
                            // the splash and the main menu. SwiftUI automatically
                            // animates the `if/else` branch change when the state
                            // mutation is wrapped in `withAnimation`.
                            withAnimation (.easeInOut (duration: 0.5)) {
                                isLoading = false
                            }
                        }
                    }
            } else {
                // MARK: Main Menu
                ContentView ()
            }
        }
    }
}
