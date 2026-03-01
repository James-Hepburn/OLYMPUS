import SwiftUI

// MARK: - OlympusButton
/// A reusable primary action button styled to match OLYMPUS's dark, red-accented
/// visual theme.
///
/// Used exclusively on the main menu to keep the call-to-action buttons visually
/// consistent. The component manages its own press state internally so callers
/// only need to supply a title string and an action closure — no additional
/// configuration is required.
///
/// The press interaction is driven by a `DragGesture` with zero minimum distance
/// rather than a standard `ButtonStyle`. This approach gives precise control over
/// the pressed appearance (scale, opacity, shadow bloom) for both the down and
/// up phases of the tap, which a plain `ButtonStyle` does not expose cleanly.
struct OlympusButton: View {

    // MARK: Inputs

    /// The label displayed inside the button (e.g. "VS AI", "How to Play").
    let title: String

    /// The closure executed when the button is tapped. Passed through from the
    /// parent without modification so `OlympusButton` remains a pure UI component
    /// with no knowledge of navigation or business logic.
    let action: () -> Void

    // MARK: State

    /// Tracks whether the button is currently being pressed. Toggled by the
    /// `DragGesture` modifiers and used to drive the visual feedback animations.
    @State private var isPressed = false

    // MARK: Body

    var body: some View {
        Button (action: {
            action ()
        }) {
            Text (title)
                .font (.title2)
                .foregroundColor (.white)
                .frame (width: 170, height: 50)
                // Background dims slightly on press to reinforce the tactile feel.
                .background (isPressed ? Color.red.opacity (0.3) : Color.gray.opacity (0.3))
                .cornerRadius (10)
                .overlay (
                    RoundedRectangle (cornerRadius: 10)
                        .stroke (Color.red, lineWidth: 2)
                        // Inner shadow on the stroke blooms when pressed, adding
                        // a glow that makes the interaction feel energetic.
                        .shadow (color: .red, radius: isPressed ? 12 : 4)
                )
                // Slight shrink on press gives physical "click" feedback.
                .scaleEffect (isPressed ? 0.94 : 1.0)
                // Outer red glow intensifies on press for an additional layer of
                // visual feedback consistent with the app's neon aesthetic.
                .shadow (color: Color.red.opacity (isPressed ? 0.8 : 0.3), radius: isPressed ? 16 : 6)
        }
        .buttonStyle (PlainButtonStyle ())
        // A zero-distance DragGesture is used instead of `.onLongPressGesture` or
        // a custom ButtonStyle because it provides reliable callbacks for both the
        // start (.onChanged) and end (.onEnded) of a press, enabling smooth
        // animation in both directions without the delay that LongPressGesture introduces.
        .simultaneousGesture (
            DragGesture (minimumDistance: 0)
                .onChanged { _ in
                    withAnimation (.easeInOut (duration: 0.1)) {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    withAnimation (.easeInOut (duration: 0.15)) {
                        isPressed = false
                    }
                }
        )
        .padding ()
    }
}

// MARK: - ContentView
/// The main menu screen and root of the OLYMPUS navigation hierarchy.
///
/// Acts as the app's hub, presenting four primary destinations via
/// `NavigationStack` and `navigationDestination` modifiers:
/// - **VS AI** — single-player game against the AI (`GameBoardView`)
/// - **VS Human** — online multiplayer matchmaking (`WaitingForOpponentView`)
/// - **How to Play** — rules and tutorial (`HowToPlayView`)
/// - **View All Cards** — browsable card library (`AllCardsView`)
///
/// Navigation is driven by four `@State` Boolean flags rather than a single
/// enum-based route. This keeps each destination independent — navigating to one
/// does not affect the state of the others — and avoids the boilerplate of a
/// custom `Hashable` route type for a menu with only four destinations.
struct ContentView: View {

    // MARK: Navigation State

    /// Controls navigation to the How to Play screen.
    @State private var goToHowToPlay = false

    /// Controls navigation to the full card library.
    @State private var goToAllCards = false

    /// Controls navigation to the single-player AI game board.
    @State private var goToVsAI = false

    /// Controls navigation to the multiplayer matchmaking waiting room.
    @State private var goToVsHuman = false

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack {
                // Full-bleed dark background consistent with every other screen.
                Color (hex: "111111").ignoresSafeArea ()

                VStack (spacing: 20) {

                    // MARK: Logo
                    // Large heavy-weight title with a double-layered red glow.
                    // Two `.shadow` modifiers at different radii simulate a bloom
                    // effect: the tighter radius creates a hard inner glow, while
                    // the wider one produces a softer ambient halo.
                    Text ("OLYMPUS")
                        .font (.system (size: 70, weight: .heavy))
                        .foregroundColor (Color.red)
                        .padding (.bottom, 20)
                        .shadow (color: .red, radius: 20)
                        .shadow (color: .red, radius: 40)

                    // MARK: Navigation Buttons
                    // Each button flips its corresponding Boolean flag, which
                    // immediately triggers the matching `navigationDestination`.
                    OlympusButton (title: "VS AI")      { goToVsAI    = true }
                    OlympusButton (title: "VS Human")   { goToVsHuman = true }
                    OlympusButton (title: "How to Play"){ goToHowToPlay = true }
                    OlympusButton (title: "View All Cards") { goToAllCards = true }
                }
                .padding ()
            }
            .navigationBarHidden (true)

            // MARK: Navigation Destinations
            // Each destination is registered separately so SwiftUI can resolve
            // the correct view type at compile time. The `isPresented` binding
            // is automatically reset to `false` when the user navigates back,
            // so the button is ready to be tapped again without manual cleanup.
            .navigationDestination (isPresented: $goToVsAI) {
                GameBoardView (mode: .vsAI)
            }
            .navigationDestination (isPresented: $goToVsHuman) {
                WaitingForOpponentView ()
            }
            .navigationDestination (isPresented: $goToHowToPlay) {
                HowToPlayView ()
            }
            .navigationDestination (isPresented: $goToAllCards) {
                AllCardsView ()
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView ()
}
