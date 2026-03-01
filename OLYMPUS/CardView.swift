import SwiftUI

// MARK: - Color + Hex Initialiser
/// Extends SwiftUI's `Color` with a convenience initialiser that accepts a
/// six-digit hexadecimal string (e.g. `"FFD700"`).
///
/// This extension is the single point of conversion between the hex colour
/// constants defined in `CardType.borderColors` and the `Color` values consumed
/// throughout the UI. Centralising the conversion here means every view in the
/// app can use hex strings directly without duplicating parsing logic.
///
/// The implementation scans the string into a `UInt64`, then bit-shifts and
/// masks to extract the red, green, and blue channels as normalised `Double`
/// values in the range [0, 1].
extension Color {
    init (hex: String) {
        // Strip any leading `#` or whitespace so callers don't need to worry
        // about the exact format of the input string.
        let hex = hex.trimmingCharacters (in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner (string: hex).scanHexInt64 (&int)
        let r = Double ((int >> 16) & 0xFF) / 255
        let g = Double ((int >> 8)  & 0xFF) / 255
        let b = Double (int         & 0xFF) / 255
        self.init (red: r, green: g, blue: b)
    }
}

// MARK: - CardView
/// The visual representation of a single `Card`, used across every screen in
/// the app — the card library, both game board variants, and the detail sheet.
///
/// The component is intentionally self-contained: it derives every visual
/// decision (background colour, border gradient, stat icons, placeholder icon)
/// from the `Card` model and two optional flags, so callers only need to pass
/// in data and the view handles its own appearance.
///
/// Layout overview (top to bottom within the fixed 120×180 pt frame):
/// ```
/// ┌────────────────────┐
/// │   Artwork (90 pt)  │  ← image asset or SF Symbol fallback
/// ├────────────────────┤  ← 1 pt gradient divider
/// │  Name  │  Type     │
/// │  Description text  │  ← up to 4 lines, scaled down if needed
/// │  [mana]  [atk][hp] │  ← stat row (omits atk/hp for spells)
/// └────────────────────┘
/// ```
struct CardView: View {

    // MARK: Inputs

    /// The data model this view renders. All visual properties are derived from
    /// this value — no separate configuration is needed.
    let card: Card

    /// When `true`, a subtle white overlay and enlarged border are applied to
    /// indicate the card is actively selected by the player (e.g. chosen from hand
    /// before playing or targeting). Animated with a spring so the highlight
    /// feels responsive rather than abrupt.
    var isSelected: Bool = false

    /// When `false`, the card is rendered at 45% opacity to signal that it cannot
    /// currently be played — typically because the player doesn't have enough mana.
    /// This gives instant visual feedback without disabling tap gestures on the parent.
    var isPlayable: Bool = true

    // MARK: Constants

    /// Fixed card dimensions used throughout the layout. Keeping these as named
    /// constants avoids magic numbers and makes it trivial to rescale the card
    /// if the design changes.
    private let cardWidth:  CGFloat = 120
    private let cardHeight: CGFloat = 180

    // MARK: Computed Properties

    /// A diagonal linear gradient built from the two hex colours defined in
    /// `CardType.borderColors`. Applied to the card's border stroke and the
    /// thin divider between the artwork and the info panel, tying the card's
    /// visual identity to its type at a glance.
    var borderGradient: LinearGradient {
        let colors = card.type.borderColors.map { Color (hex: $0) }
        return LinearGradient (colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Body

    var body: some View {
        ZStack (alignment: .topLeading) {

            // MARK: Background
            // Each card type has a unique near-black background tint that subtly
            // reinforces the type's colour identity without competing with the artwork.
            RoundedRectangle (cornerRadius: 10)
                .fill (cardBackground)
                .frame (width: cardWidth, height: cardHeight)

            // MARK: Selection Overlay
            // A semi-transparent white layer added on top of the background when
            // the card is selected, brightening it just enough to stand out from
            // unselected neighbours without obscuring the artwork or stats.
            if isSelected {
                RoundedRectangle (cornerRadius: 10)
                    .fill (Color.white.opacity (0.08))
                    .frame (width: cardWidth, height: cardHeight)
            }

            VStack (spacing: 0) {

                // MARK: Artwork Panel (top half)
                ZStack {
                    // Attempt to load a named image asset. During development, not
                    // all assets may be available, so a type-appropriate SF Symbol
                    // is shown as a placeholder to keep the layout intact.
                    if UIImage (named: card.imageName) != nil {
                        Image (card.imageName)
                            .interpolation (.none)  // Preserve pixel-art crispness if assets are low-res.
                            .resizable ()
                            .scaledToFill ()
                            .frame (width: cardWidth, height: cardHeight / 2)
                            .clipped ()             // Prevent scaledToFill from bleeding outside the frame.
                    } else {
                        // Fallback placeholder — uses a per-type icon so the card
                        // still communicates its category even without real artwork.
                        Image (systemName: placeholderIcon)
                            .font (.system (size: 32))
                            .foregroundColor (Color (hex: card.type.borderColors [0]).opacity (0.4))
                            .frame (width: cardWidth, height: cardHeight / 2)
                    }
                }

                // Thin gradient divider between artwork and info panel.
                // Uses the same `borderGradient` as the card outline so the
                // type colour runs consistently through the entire component.
                Rectangle ()
                    .fill (borderGradient)
                    .frame (height: 1)

                // MARK: Info Panel (bottom half)
                VStack (alignment: .leading, spacing: 3) {

                    // Card name and type badge on the same line.
                    // `minimumScaleFactor` allows long names (e.g. "Lightning Bolt")
                    // to compress rather than truncate ungracefully.
                    HStack (alignment: .firstTextBaseline, spacing: 4) {
                        Text (card.name)
                            .font (.system (size: 9, weight: .bold))
                            .foregroundColor (.white)
                            .lineLimit (1)
                            .minimumScaleFactor (0.7)

                        Text (card.type.label.uppercased ())
                            .font (.system (size: 6, weight: .semibold))
                            .foregroundColor (Color (hex: card.type.borderColors [0]))
                    }
                    .padding (.horizontal, 7)
                    .padding (.top, 5)

                    // Ability / flavour description. Capped at 4 lines with a scale
                    // factor to handle verbose descriptions without layout overflow.
                    Text (card.description)
                        .font (.system (size: 7))
                        .foregroundColor (Color.white.opacity (0.8))
                        .multilineTextAlignment (.leading)
                        .lineLimit (4)
                        .minimumScaleFactor (0.75)
                        .padding (.horizontal, 7)

                    Spacer ()

                    // MARK: Stat Row
                    // Creature cards (non-spells) show mana cost on the left and
                    // Attack / Health on the right. Spell cards only show mana cost
                    // since they have no combat stats or board presence.
                    if card.type != .spell {
                        HStack {
                            // Mana cost bubble — blue circle consistent with the
                            // mana colour used everywhere in the app.
                            ZStack {
                                Circle ()
                                    .fill (Color (hex: "1a6fd4"))
                                    .frame (width: 20, height: 20)
                                Text ("\(card.manaCost)")
                                    .font (.system (size: 11, weight: .black))
                                    .foregroundColor (.white)
                            }

                            Spacer ()

                            // Attack and health displayed as icon + number pairs.
                            // `currentAttack` and `currentHealth` are used (not the
                            // base values) so any in-game buffs or damage are
                            // immediately reflected on the card face.
                            HStack (spacing: 6) {
                                HStack (spacing: 2) {
                                    Image (systemName: "bolt.fill")
                                        .font (.system (size: 8))
                                        .foregroundColor (.orange)
                                    Text ("\(card.currentAttack ?? 0)")
                                        .font (.system (size: 12, weight: .black))
                                        .foregroundColor (.orange)
                                }
                                HStack (spacing: 2) {
                                    Image (systemName: "heart.fill")
                                        .font (.system (size: 8))
                                        .foregroundColor (.red)
                                    Text ("\(card.currentHealth ?? 0)")
                                        .font (.system (size: 12, weight: .black))
                                        .foregroundColor (.red)
                                }
                            }
                        }
                        .padding (.horizontal, 7)
                        .padding (.bottom, 6)
                    } else {
                        // Spell cards: mana cost bubble only, left-aligned.
                        HStack {
                            ZStack {
                                Circle ()
                                    .fill (Color (hex: "1a6fd4"))
                                    .frame (width: 20, height: 20)
                                Text ("\(card.manaCost)")
                                    .font (.system (size: 11, weight: .black))
                                    .foregroundColor (.white)
                            }
                            Spacer ()
                        }
                        .padding (.horizontal, 7)
                        .padding (.bottom, 6)
                    }
                }
                .frame (width: cardWidth, height: cardHeight / 2)
            }
        }
        .frame (width: cardWidth, height: cardHeight)
        // Clip the entire ZStack so the background fill and overlay both
        // respect the rounded corners without needing individual clipping.
        .clipShape (RoundedRectangle (cornerRadius: 10))
        // Gradient border — thicker (3 pt) when selected to make the highlight
        // unmissable, thinner (2 pt) at rest.
        .overlay {
            RoundedRectangle (cornerRadius: 10)
                .strokeBorder (borderGradient, lineWidth: isSelected ? 3 : 2)
        }
        // Dim unplayable cards to signal they are unavailable without fully
        // hiding them from the hand.
        .opacity (isPlayable ? 1.0 : 0.45)
        // Subtle scale-up on selection provides tactile feedback that a card
        // has been registered as the active choice.
        .scaleEffect (isSelected ? 1.05 : 1.0)
        .animation (.easeInOut (duration: 0.15), value: isSelected)
        // The drop shadow blooms when selected, reinforcing the glow effect
        // created by the wider border and scale increase.
        .shadow (color: isSelected ? Color (hex: card.type.borderColors [0]).opacity (0.8) : Color.black.opacity (0.4),
                 radius: isSelected ? 12 : 4)
    }

    // MARK: Helpers

    /// Returns the near-black background tint appropriate for the card's type.
    /// Each colour is a very dark version of the type's primary accent colour,
    /// giving a cohesive look when the card is viewed against the app's `#111111`
    /// background.
    var cardBackground: Color {
        switch card.type {
        case .god:     return Color (hex: "1a1400")   // Dark gold tint
        case .hero:    return Color (hex: "0d0d0d")   // Neutral near-black
        case .monster: return Color (hex: "120800")   // Dark amber tint
        case .spell:   return Color (hex: "0d0014")   // Dark purple tint
        }
    }

    /// Returns the SF Symbol name used as a placeholder when the card's named
    /// image asset is not available in the asset catalogue. Each symbol was
    /// chosen to be thematically appropriate for its card type.
    var placeholderIcon: String {
        switch card.type {
        case .god:     return "sparkles"        // Divinity / magic
        case .hero:    return "person.fill"     // Human figure
        case .monster: return "flame.fill"      // Danger / chaos
        case .spell:   return "wand.and.stars"  // Arcane magic
        }
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color (hex: "111111").ignoresSafeArea ()
    }
}
