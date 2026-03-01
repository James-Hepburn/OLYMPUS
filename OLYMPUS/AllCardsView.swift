import SwiftUI

// MARK: - AllCardsView
/// The card library screen, accessible from the main menu.
/// Displays the full collection of 30 cards in a responsive grid and supports
/// filtering by card type (Gods, Heroes, Monsters, Spells).
///
/// Tapping any card presents a `CardDetailView` modal with an enlarged card
/// rendering and full stat breakdown.
struct AllCardsView: View {

    // MARK: State

    /// The currently active type filter. When `nil`, all cards are shown.
    @State private var selectedType: CardType? = nil

    /// The card the user has tapped, used to drive the detail sheet presentation.
    /// Setting this to a non-nil value automatically triggers the `.sheet` modifier.
    @State private var selectedCard: Card? = nil

    // MARK: Layout

    /// A single adaptive column definition that allows SwiftUI to fit as many
    /// 120 pt-wide cards per row as the screen width permits, spacing them 16 pt apart.
    /// This keeps the grid readable on both iPhone and iPad without any manual
    /// breakpoint logic.
    let columns = [
        GridItem (.adaptive (minimum: 120), spacing: 16)
    ]

    // MARK: Computed Properties

    /// Returns the subset of cards that match the active filter, or the full
    /// collection when no filter is selected. This is recomputed automatically
    /// whenever `selectedType` changes, keeping the grid in sync with the filter bar.
    var filteredCards: [Card] {
        guard let type = selectedType else { return Card.allCards }
        return Card.allCards.filter { $0.type == type }
    }

    // MARK: Body

    var body: some View {
        ZStack {
            // Full-bleed dark background consistent with the app's visual theme.
            Color (hex: "111111").ignoresSafeArea ()

            VStack (spacing: 0) {

                // MARK: Filter Bar
                // A horizontal row of toggle buttons — one per card type plus "All".
                // Tapping an already-selected filter deselects it, restoring the full grid.
                // Each tap is wrapped in `withAnimation` so the grid transition is smooth.
                HStack (spacing: 10) {
                    FilterTab (label: "All", isSelected: selectedType == nil) {
                        withAnimation { selectedType = nil }
                    }
                    FilterTab (label: "Gods", color: "FFD700", isSelected: selectedType == .god) {
                        withAnimation { selectedType = selectedType == .god ? nil : .god }
                    }
                    FilterTab (label: "Heroes", color: "C0C0C0", isSelected: selectedType == .hero) {
                        withAnimation { selectedType = selectedType == .hero ? nil : .hero }
                    }
                    FilterTab (label: "Monsters", color: "CD7F32", isSelected: selectedType == .monster) {
                        withAnimation { selectedType = selectedType == .monster ? nil : .monster }
                    }
                    FilterTab (label: "Spells", color: "9B59B6", isSelected: selectedType == .spell) {
                        withAnimation { selectedType = selectedType == .spell ? nil : .spell }
                    }
                }
                .padding (.horizontal)
                .padding (.vertical, 12)

                // Subtle red-tinted divider that visually separates the filter bar
                // from the card grid below without breaking the dark aesthetic.
                Divider ().background (Color.red.opacity (0.4))

                // MARK: Card Grid
                // `LazyVGrid` with `LazyVGrid` ensures only visible cards are rendered,
                // keeping memory usage low even as the full card set grows over time.
                ScrollView {
                    LazyVGrid (columns: columns, spacing: 20) {
                        ForEach (filteredCards) { card in
                            CardView (card: card)
                                .onTapGesture {
                                    // Assigning to `selectedCard` triggers the `.sheet`
                                    // modifier below, opening the detail view for this card.
                                    selectedCard = card
                                }
                        }
                    }
                    .padding ()
                }
            }
        }
        .navigationTitle ("All Cards")
        .navigationBarTitleDisplayMode (.inline)
        .toolbarColorScheme (.dark, for: .navigationBar)
        // Sheet is bound to `selectedCard` — SwiftUI presents it automatically when
        // the value becomes non-nil and dismisses it when the binding is cleared.
        .sheet (item: $selectedCard) { card in
            CardDetailView (card: card)
        }
    }
}

// MARK: - FilterTab
/// A compact toggle button used in the `AllCardsView` filter bar.
///
/// Each tab has a theme colour matching its card type. When selected, the tab
/// fills with that colour and inverts the label to black for contrast. When
/// deselected, it shows a low-opacity tinted background with a coloured border,
/// keeping all options visible at a glance.
struct FilterTab: View {
    let label: String

    /// Hex colour string for the tab's accent colour. Defaults to the app's
    /// primary red so the "All" tab requires no explicit colour argument.
    var color: String = "FF3B30"

    /// Whether this tab is the currently active filter.
    let isSelected: Bool

    /// Callback invoked when the user taps the tab.
    let action: () -> Void

    var body: some View {
        Button (action: action) {
            Text (label)
                .font (.system (size: 12, weight: .semibold))
                // Invert text colour on selection so it remains legible against
                // the filled background.
                .foregroundColor (isSelected ? .black : Color(hex: color))
                .padding (.horizontal, 10)
                .padding (.vertical, 6)
                // Solid fill when selected; subtle tinted fill when idle.
                .background (isSelected ? Color (hex: color) : Color (hex: color).opacity (0.15))
                .cornerRadius (8)
                .overlay (
                    // Always-visible border reinforces the type colour even when unselected.
                    RoundedRectangle (cornerRadius: 8)
                        .stroke (Color (hex: color), lineWidth: 1)
                )
        }
    }
}

// MARK: - CardDetailView
/// A full-screen modal that presents an enlarged view of a single card alongside
/// its complete stat block and flavour description.
///
/// Presented as a `.sheet` from `AllCardsView` when the user taps a card in the grid.
/// The card artwork is scaled to 2× its normal size so artwork and text are
/// comfortably readable without navigating away from the library.
struct CardDetailView: View {
    let card: Card

    /// Provides the programmatic dismiss action so the "Close" button can
    /// pop this sheet without needing a binding passed down from the parent.
    @Environment(\.dismiss) var dismiss

    // MARK: Computed Properties

    /// Constructs a diagonal linear gradient from the card type's two border colours.
    /// Used to stroke the stat-block container, giving each card type a distinct
    /// visual identity in the detail panel (gold for gods, silver for heroes, etc.).
    var borderGradient: LinearGradient {
        let colors = card.type.borderColors.map { Color (hex: $0) }
        return LinearGradient (colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Body

    var body: some View {
        ZStack {
            // Consistent dark background matching the rest of the app.
            Color (hex: "111111").ignoresSafeArea ()

            VStack (spacing: 24) {

                // MARK: Enlarged Card Preview
                // Reuses the same `CardView` component from the game board, scaled up
                // to 2× so the artwork and inline stats are clearly visible.
                // Extra bottom padding compensates for the scale transform expanding
                // the card's visual footprint downward.
                CardView (card: card)
                    .scaleEffect (2.0)
                    .padding (.top, 40)
                    .padding (.bottom, 80)

                // MARK: Stat Block
                // A frosted-glass-style container that groups the card name, type badge,
                // description, and numeric stats. The gradient border matches the card's
                // type colours so the panel feels visually connected to the card above it.
                VStack (alignment: .leading, spacing: 12) {

                    // Card name (large) and type badge side-by-side.
                    HStack {
                        Text (card.name)
                            .font (.system (size: 28, weight: .heavy))
                            .foregroundColor (.white)
                        Spacer ()
                        // Type label pill — outlined in the primary border colour of the
                        // card's type to mirror the card's own aesthetic.
                        Text (card.type.label.uppercased ())
                            .font (.system (size: 13, weight: .bold))
                            .foregroundColor (Color (hex: card.type.borderColors [0]))
                            .padding (.horizontal, 10)
                            .padding (.vertical, 4)
                            .overlay (
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke (Color (hex: card.type.borderColors [0]), lineWidth: 1)
                            )
                    }

                    Divider ().background (Color.white.opacity (0.2))

                    // Full ability / flavour description pulled directly from the card model.
                    Text (card.description)
                        .font (.system (size: 15))
                        .foregroundColor (.white.opacity (0.85))
                        .multilineTextAlignment (.leading)

                    // MARK: Stats Row
                    // Creature cards (non-spells) expose Attack, Health, and Mana Cost.
                    // Spell cards have no combat stats, so only Mana Cost is shown.
                    if card.type != .spell, let atk = card.attack, let hp = card.health {
                        HStack (spacing: 24) {
                            // Attack — orange to convey offensive power.
                            HStack (spacing: 6) {
                                Image (systemName: "bolt.fill").foregroundColor (.orange)
                                Text ("Attack: \(atk)")
                                    .font (.system (size: 15, weight: .semibold))
                                    .foregroundColor (.orange)
                            }
                            // Health — red to signal vitality / survivability.
                            HStack (spacing: 6) {
                                Image (systemName: "heart.fill").foregroundColor (.red)
                                Text ("Health: \(hp)")
                                    .font (.system (size: 15, weight: .semibold))
                                    .foregroundColor (.red)
                            }
                            // Mana cost — blue, the universal colour for mana in the app.
                            HStack (spacing: 6) {
                                Image (systemName: "drop.fill").foregroundColor (Color (hex: "1a6fd4"))
                                Text ("Mana: \(card.manaCost)")
                                    .font (.system(size: 15, weight: .semibold))
                                    .foregroundColor (Color (hex: "1a6fd4"))
                            }
                        }
                    } else {
                        // Spell cards only display mana cost since they have no board presence.
                        HStack (spacing: 6) {
                            Image (systemName: "drop.fill").foregroundColor (Color (hex: "1a6fd4"))
                            Text ("Mana Cost: \(card.manaCost)")
                                .font (.system (size: 15, weight: .semibold))
                                .foregroundColor (Color (hex: "1a6fd4"))
                        }
                    }
                }
                .padding (20)
                .background (Color.white.opacity (0.05))
                .cornerRadius (14)
                // Gradient border derived from the card's type colours, matching the
                // card preview above for visual cohesion.
                .overlay (
                    RoundedRectangle (cornerRadius: 14)
                        .strokeBorder (borderGradient, lineWidth: 1.5)
                )
                .padding (.horizontal)

                // MARK: Dismiss Button
                // Calls the SwiftUI environment dismiss action to close the sheet cleanly.
                Button ("Close") { dismiss () }
                    .font (.system (size: 16, weight: .semibold))
                    .foregroundColor (.white)
                    .frame (width: 140, height: 44)
                    .background (Color.red.opacity (0.25))
                    .cornerRadius (10)
                    .overlay (
                        RoundedRectangle (cornerRadius: 10)
                            .stroke (Color.red, lineWidth: 1.5)
                    )
                    .padding (.bottom, 30)
            }
        }
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        AllCardsView ()
    }
}
