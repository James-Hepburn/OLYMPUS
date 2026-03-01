import SwiftUI

// MARK: - WaitingForOpponentView
/// The matchmaking screen shown when the player taps "VS Human" on the main menu.
///
/// This view owns the `MultiplayerManager` instance for the entire online match
/// lifecycle — from searching through gameplay to the game-over overlay. It is
/// instantiated as a `@StateObject` here (rather than passed in from `ContentView`)
/// so that `MultiplayerManager`'s Firebase connection and match state are tied
/// to this view's lifetime. When the player navigates away, the view is destroyed
/// and the manager is deallocated, automatically cleaning up the connection.
///
/// The view renders one of four states driven by `manager.matchmakingState`:
/// - **`.idle`** — transitional; shown briefly before `findMatch()` fires on appear.
/// - **`.searching`** — animated spinner while waiting for an opponent.
/// - **`.matched`** — hands off to `MultiplayerGameBoardView` in-place, so the
///   navigation bar stays hidden and no push/pop animation interrupts the transition.
/// - **`.error`** — displays the Firebase error message with a "Go Back" button.
struct WaitingForOpponentView: View {

    // MARK: State & Environment

    /// The multiplayer session manager. Owned here as a `@StateObject` so it
    /// persists across re-renders for the full match duration and is released
    /// when this view is dismissed.
    @StateObject private var manager = MultiplayerManager ()

    /// Used by the Cancel and Go Back buttons to pop back to the main menu
    /// without requiring a navigation binding.
    @Environment(\.dismiss) var dismiss

    /// The animated ellipsis suffix appended to "Finding Opponent".
    /// Cycles through `""`, `"."`, `".."`, `"..."` every 0.5 seconds, driven
    /// by `dotTimer`. Updating `dots` also indirectly triggers the spinner
    /// animation — see the `animation(value:)` note below.
    @State private var dots = ""

    /// The repeating `Timer` that advances the ellipsis animation.
    /// Stored as optional state so it can be invalidated in `onDisappear`,
    /// preventing a retain cycle if the view is dismissed before the timer fires.
    @State private var dotTimer: Timer? = nil

    // MARK: Body

    var body: some View {
        ZStack {
            Color (hex: "111111").ignoresSafeArea ()

            // The entire matchmaking and gameplay flow is driven by a single
            // `switch` on `matchmakingState`, keeping all state transitions in
            // one place and making the flow easy to reason about at a glance.
            switch manager.matchmakingState {

            // MARK: Idle
            // Momentary state between view appear and the first Firebase response.
            // Renders nothing to avoid a flash of content before the searching
            // UI appears.
            case .idle:
                EmptyView ()

            // MARK: Searching
            // Animated spinner + ellipsis label shown while waiting for an opponent.
            case .searching:
                VStack (spacing: 32) {
                    Spacer ()

                    VStack (spacing: 16) {

                        // MARK: Spinner
                        // Built from two layered circles:
                        // 1. A faint full circle as the track.
                        // 2. A trimmed arc (70% of the circumference) with a
                        //    red-to-transparent gradient and rounded line caps,
                        //    rotated -90° so the arc starts at the top (12 o'clock)
                        //    rather than the default 3 o'clock position.
                        //
                        // The arc's continuous rotation is driven by an
                        // `Animation.linear.repeatForever` tied to the `dots` value.
                        // Using `dots` as the animation value is a deliberate trick:
                        // SwiftUI needs a changing value to restart a `repeatForever`
                        // animation after a re-render, and `dots` changes every 0.5s,
                        // keeping the spinner running smoothly without a dedicated
                        // rotation state variable.
                        ZStack {
                            Circle ()
                                .stroke (Color.red.opacity (0.15), lineWidth: 2)
                                .frame (width: 100, height: 100)
                            Circle ()
                                .trim (from: 0, to: 0.7)
                                .stroke (
                                    LinearGradient (colors: [Color.red, Color.red.opacity (0.2)], startPoint: .leading, endPoint: .trailing),
                                    style: StrokeStyle (lineWidth: 3, lineCap: .round)
                                )
                                .frame (width: 100, height: 100)
                                .rotationEffect (.degrees (-90))   // Start arc at 12 o'clock.
                                .animation (Animation.linear (duration: 1.2).repeatForever (autoreverses: false), value: dots)
                            Image (systemName: "person.2.fill")
                                .font (.system (size: 32))
                                .foregroundColor (.white.opacity (0.6))
                        }

                        // Animated ellipsis: "Finding Opponent", "Finding Opponent.",
                        // "Finding Opponent..", "Finding Opponent..." on a 0.5s cycle.
                        Text ("Finding Opponent\(dots)")
                            .font (.system (size: 22, weight: .heavy))
                            .foregroundColor (.white)

                        Text ("Waiting for another player to connect...")
                            .font (.system (size: 14))
                            .foregroundColor (.white.opacity (0.5))
                            .multilineTextAlignment (.center)
                    }

                    Spacer ()

                    // Cancel — calls `manager.cancelSearch()` to remove the lobby
                    // entry from Firebase before dismissing, preventing the room
                    // from appearing as a joinable room for other players.
                    Button ("Cancel") {
                        manager.cancelSearch ()
                        dismiss ()
                    }
                    .font (.system (size: 16, weight: .semibold))
                    .foregroundColor (.white)
                    .frame (width: 160, height: 48)
                    .background (Color.red.opacity (0.2))
                    .cornerRadius (10)
                    .overlay (RoundedRectangle (cornerRadius: 10).stroke (Color.red, lineWidth: 1.5))
                    .padding (.bottom, 50)
                }
                .padding (.horizontal, 40)

            // MARK: Matched
            // Once a match is found, `MultiplayerGameBoardView` replaces this
            // view's content in-place rather than being pushed onto the navigation
            // stack. This keeps `.navigationBarHidden(true)` effective for the
            // entire match without a separate `NavigationLink`, and avoids the
            // push animation that would otherwise flash between matchmaking and
            // gameplay.
            //
            // `manager.gameSnapshot` is guaranteed non-nil at this point (the
            // manager only transitions to `.matched` after the snapshot is written),
            // but the `if let` unwrap with a `ProgressView` fallback is retained
            // as a defensive guard for the brief window between state change and
            // the first Firebase propagation.
            case .matched:
                if let snap = manager.gameSnapshot {
                    MultiplayerGameBoardView (manager: manager, initialSnapshot: snap)
                } else {
                    // Fallback spinner — shown only during the sub-100ms window
                    // before the first snapshot arrives after transitioning to matched.
                    ProgressView ()
                        .tint (.white)
                }

            // MARK: Error
            // Displays the Firebase error string with a "Go Back" button.
            // The error message is surfaced directly rather than being translated
            // to a user-friendly string, which is acceptable for a development-
            // stage app — a production release would map common error codes to
            // localised messages.
            case .error (let msg):
                VStack (spacing: 20) {
                    Image (systemName: "exclamationmark.triangle.fill")
                        .font (.system (size: 40))
                        .foregroundColor (.red)
                    Text ("Connection Error")
                        .font (.system (size: 22, weight: .heavy))
                        .foregroundColor (.white)
                    Text (msg)
                        .font (.system (size: 14))
                        .foregroundColor (.white.opacity (0.6))
                        .multilineTextAlignment (.center)
                    Button ("Go Back") { dismiss () }
                        .font (.system (size: 16, weight: .semibold))
                        .foregroundColor (.white)
                        .padding (.horizontal, 24).padding (.vertical, 12)
                        .background (Color.red.opacity (0.2)).cornerRadius (10)
                        .overlay (RoundedRectangle (cornerRadius: 10).stroke (Color.red, lineWidth: 1.5))
                }
                .padding (40)
            }
        }
        .navigationBarHidden (true)
        .onAppear {
            // Kick off matchmaking immediately on appear.
            manager.findMatch ()

            // Start the ellipsis timer. The closure cycles `dots` through
            // "", ".", "..", "..." and back to "" every 0.5 seconds.
            // `dotTimer` is stored so `onDisappear` can invalidate it,
            // preventing the closure from running after the view is gone.
            dotTimer = Timer.scheduledTimer (withTimeInterval: 0.5, repeats: true) { _ in
                dots = dots.count >= 3 ? "" : dots + "."
            }
        }
        .onDisappear {
            // Invalidate the timer on disappear to stop it firing after the
            // view is no longer on screen. Without this, the timer would
            // continue running and mutating `dots` indefinitely.
            dotTimer?.invalidate ()
        }
    }
}
