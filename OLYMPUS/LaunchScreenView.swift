import SwiftUI

// MARK: - LaunchScreenView
/// The animated splash screen displayed for approximately five seconds when the
/// app first launches, before transitioning to `ContentView`.
///
/// The view is shown by `OLYMPUSApp` while `isLoading` is `true`. After a
/// fixed delay, `OLYMPUSApp` flips `isLoading` to `false` and SwiftUI replaces
/// this view with `ContentView` using the `.easeInOut` transition defined there.
///
/// The entrance animation runs once on appear: the logo and tagline scale up
/// from 85% to 100% and fade in from transparent to opaque over 0.6 seconds.
/// Starting below full scale gives the text a subtle "settle into place" feel
/// that is more engaging than a straight fade alone.
struct LaunchScreenView: View {

    // MARK: Animation State

    /// Drives the fade-in. Starts at `0.0` (fully transparent) and animates
    /// to `1.0` (fully opaque) on appear.
    @State private var opacity = 0.0

    /// Drives the scale-up. Starts at `0.85` (slightly small) and animates
    /// to `1.0` (natural size) on appear, producing a gentle zoom-in effect
    /// that makes the title feel like it's arriving rather than simply appearing.
    @State private var scale = 0.85

    // MARK: Body

    var body: some View {
        ZStack {
            // Full-bleed dark background matching the rest of the app, ensuring
            // there is no flash of a lighter system background during launch.
            Color (hex: "111111").ignoresSafeArea ()

            VStack (spacing: 16) {

                // MARK: App Title
                // Heavy weight at 70 pt matches the logo on `ContentView` exactly,
                // so the transition from launch screen to main menu feels seamless.
                // The red glow shadow reinforces the app's visual identity from
                // the first moment the user sees it.
                Text ("OLYMPUS")
                    .font (.system (size: 70, weight: .heavy))
                    .foregroundColor (.red)
                    .shadow (color: .red, radius: 20)

                // MARK: Tagline
                // Subdued opacity keeps the tagline from competing with the title
                // while still setting a mythological tone for the experience ahead.
                Text ("May the gods favour you.")
                    .font (.system (size: 16))
                    .foregroundColor (.white.opacity (0.4))
            }
            // Both scale and opacity are applied to the VStack as a whole so
            // the title and tagline animate together as a single unit.
            .scaleEffect (scale)
            .opacity (opacity)
            .onAppear {
                // `easeOut` decelerates as it approaches the final values,
                // giving the animation a natural, gravity-like settling feel.
                withAnimation (.easeOut (duration: 0.6)) {
                    opacity = 1.0
                    scale   = 1.0
                }
            }
        }
    }
}
