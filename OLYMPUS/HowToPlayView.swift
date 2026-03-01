import SwiftUI

// MARK: - HowToPlayView
/// A tabbed tutorial screen that walks new players through the rules of OLYMPUS.
///
/// Content is divided into four sections, each rendered by a dedicated sub-view:
/// - **Basics** — health, mana, drawing, and the win condition.
/// - **Card Types** — creatures, spells, and gods explained.
/// - **Your Turn** — the step-by-step turn structure.
/// - **The Deck** — card composition and distribution.
///
/// Navigation between sections is driven by a horizontal tab bar at the top.
/// Rather than using `TabView` (which would add swipe gesture conflicts with the
/// horizontal scroll), sections are swapped in a `switch` block inside a single
/// `ScrollView`, keeping scroll direction unambiguous for the player.
struct HowToPlayView: View {

    // MARK: State

    /// The index of the currently visible section, driven by the tab bar buttons.
    @State private var selectedSection = 0

    /// Display labels for the four tutorial sections, used to populate the tab bar.
    let sections = ["Basics", "Card Types", "Your Turn", "The Deck"]

    // MARK: Body

    var body: some View {
        ZStack {
            Color (hex: "111111").ignoresSafeArea ()

            VStack (spacing: 0) {

                // MARK: Tab Bar
                // Horizontally scrollable so the tabs remain readable on small
                // screens without truncation. The active tab fills with red and
                // inverts its label colour; inactive tabs show a subtle red outline.
                ScrollView (.horizontal, showsIndicators: false) {
                    HStack (spacing: 8) {
                        ForEach (sections.indices, id: \.self) { i in
                            Button (action: {
                                withAnimation (.easeInOut (duration: 0.2)) {
                                    selectedSection = i
                                }
                            }) {
                                Text (sections [i])
                                    .font (.system (size: 14, weight: .semibold))
                                    .foregroundColor (selectedSection == i ? .black : .white)
                                    .padding (.horizontal, 16)
                                    .padding (.vertical, 9)
                                    .background (selectedSection == i ? Color.red : Color.white.opacity (0.08))
                                    .cornerRadius (8)
                                    .overlay (
                                        RoundedRectangle (cornerRadius: 8)
                                            // Border fades out on the selected tab since the
                                            // filled background already provides sufficient contrast.
                                            .stroke (Color.red.opacity (selectedSection == i ? 0 : 0.5), lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .padding (.horizontal)
                    .padding (.vertical, 14)
                }

                Divider ().background (Color.red.opacity (0.4))

                // MARK: Section Content
                // Each section is its own dedicated sub-view to keep this body
                // readable and to allow each section to manage its own layout
                // independently. `switch` on an integer index is used here instead
                // of an enum because `selectedSection` is already an `Int` from
                // the `ForEach` above, avoiding an unnecessary type conversion.
                ScrollView {
                    VStack (alignment: .leading, spacing: 0) {
                        switch selectedSection {
                        case 0: BasicsSection ()
                        case 1: CardTypesSection ()
                        case 2: YourTurnSection ()
                        case 3: TheDeckSection ()
                        default: EmptyView ()
                        }
                    }
                    .padding ()
                    .padding (.bottom, 30)
                }
            }
        }
        .navigationTitle ("How to Play")
        .navigationBarTitleDisplayMode (.inline)
        .toolbarColorScheme (.dark, for: .navigationBar)
    }
}

// MARK: - SectionTitle
/// A large bold heading used at the top of each tutorial section to clearly
/// identify the content below it. Extracted as a reusable component so all
/// section titles share identical typography and spacing without repetition.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text (text)
            .font (.system (size: 22, weight: .heavy))
            .foregroundColor (.white)
            .padding (.top, 8)
            .padding (.bottom, 12)
    }
}

// MARK: - RuleCard
/// A single rule entry displayed as an icon alongside a title and description.
///
/// Used throughout `BasicsSection` and `YourTurnSection` to present individual
/// game rules in a consistent, scannable format. The icon background uses a
/// low-opacity tint of `iconColor` to subtly reinforce the rule's theme colour
/// without competing with the text.
struct RuleCard: View {
    /// An SF Symbol name for the rule's icon (e.g. `"heart.fill"`, `"bolt.fill"`).
    let icon: String

    /// The accent colour applied to the icon and its background tint.
    let iconColor: Color

    /// A short title summarising the rule (e.g. "Starting Health").
    let title: String

    /// The full rule description, allowed to wrap across multiple lines.
    let bodyText: String

    var body: some View {
        HStack (alignment: .top, spacing: 14) {
            // Icon in a rounded square with a tinted background.
            ZStack {
                RoundedRectangle (cornerRadius: 8)
                    .fill (iconColor.opacity (0.15))
                    .frame (width: 36, height: 36)
                Image (systemName: icon)
                    .font (.system (size: 16))
                    .foregroundColor (iconColor)
            }
            VStack (alignment: .leading, spacing: 3) {
                Text (title)
                    .font (.system (size: 14, weight: .bold))
                    .foregroundColor (.white)
                // `fixedSize` prevents the description from being clipped inside
                // the HStack — it allows the text to grow vertically as needed.
                Text (bodyText)
                    .font (.system (size: 13))
                    .foregroundColor (.white.opacity (0.75))
                    .fixedSize (horizontal: false, vertical: true)
            }
            Spacer ()
        }
        .padding (14)
        .background (Color.white.opacity (0.05))
        .cornerRadius (12)
        .overlay (
            RoundedRectangle (cornerRadius: 12)
                .stroke (Color.white.opacity (0.1), lineWidth: 1)
        )
    }
}

// MARK: - StepRow
/// A numbered step in a sequential list, used in `YourTurnSection` to walk
/// the player through the phases of a turn in order.
///
/// The step number is rendered inside a red circle with both a filled background
/// and a stroke, creating a layered ring effect that makes the ordering visually
/// prominent without relying on plain text numbering.
struct StepRow: View {
    /// The step number displayed inside the circle badge.
    let number: Int

    /// The instruction text for this step.
    let text: String

    var body: some View {
        HStack (alignment: .top, spacing: 14) {
            // Numbered circle badge — fill + stroke for a two-layer ring effect.
            ZStack {
                Circle ()
                    .fill (Color.red.opacity (0.2))
                    .frame (width: 30, height: 30)
                Circle ()
                    .strokeBorder (Color.red, lineWidth: 1.5)
                    .frame (width: 30, height: 30)
                Text ("\(number)")
                    .font (.system (size: 13, weight: .black))
                    .foregroundColor (.red)
            }
            Text (text)
                .font (.system (size: 14))
                .foregroundColor (.white.opacity (0.85))
                .fixedSize (horizontal: false, vertical: true)
                .padding (.top, 6)   // Align text baseline with the centre of the circle badge.
            Spacer ()
        }
        .padding (.vertical, 4)
    }
}

// MARK: - CardTypeBlock
/// A themed information panel describing a single card type.
///
/// Displays a coloured icon, a title, a subtitle, and an arbitrary number of
/// bullet points. The panel's background, border, and icon all use the provided
/// `color`, giving each card type (Creatures, Spells, Gods) a visually distinct
/// block that mirrors the card border colours used in `CardView`.
struct CardTypeBlock: View {
    /// The card type name displayed as the panel heading (e.g. "Gods").
    let title: String

    /// A short descriptor shown beneath the title in a muted style
    /// (e.g. "Powerful rare creatures").
    let subtitle: String

    /// The accent colour for the panel's border, background tint, icon, and title.
    let color: Color

    /// An SF Symbol name for the type's icon, matching the placeholder icons
    /// used in `CardView` (e.g. `"sparkles"` for gods).
    let icon: String

    /// The bullet point strings describing the card type's rules and characteristics.
    let bullets: [String]

    var body: some View {
        VStack (alignment: .leading, spacing: 10) {
            // Header row: icon + title and subtitle.
            HStack (spacing: 10) {
                Image (systemName: icon)
                    .font (.system (size: 18))
                    .foregroundColor (color)
                VStack (alignment: .leading, spacing: 2) {
                    Text (title)
                        .font (.system (size: 16, weight: .heavy))
                        .foregroundColor (color)
                    Text (subtitle)
                        .font (.system (size: 12))
                        .foregroundColor (.white.opacity (0.5))
                }
            }

            // Bullet points — each preceded by a small filled circle in the
            // type's accent colour to visually separate items without using a
            // system list style that would be harder to theme.
            ForEach (bullets, id: \.self) { bullet in
                HStack (alignment: .top, spacing: 8) {
                    Circle ()
                        .fill (color.opacity (0.7))
                        .frame (width: 5, height: 5)
                        .padding (.top, 6)   // Align bullet dot with the first line of text.
                    Text (bullet)
                        .font (.system (size: 13))
                        .foregroundColor (.white.opacity (0.8))
                        .fixedSize (horizontal: false, vertical: true)
                }
            }
        }
        .padding (14)
        .frame (maxWidth: .infinity, alignment: .leading)
        .background (color.opacity (0.07))
        .cornerRadius (12)
        .overlay (
            RoundedRectangle (cornerRadius: 12)
                .stroke (color.opacity (0.3), lineWidth: 1.5)
        )
    }
}

// MARK: - BasicsSection
/// Explains the foundational rules of OLYMPUS: health, mana, drawing,
/// playing cards, and the win condition.
///
/// Structured as two groups separated by a sub-heading — core mechanics first,
/// then win condition — so a new player can absorb the basics before learning
/// the strategic goal.
struct BasicsSection: View {
    var body: some View {
        VStack (alignment: .leading, spacing: 12) {
            SectionTitle (text: "The Basics")

            RuleCard (icon: "heart.fill",            iconColor: .red,                  title: "Starting Health",   bodyText: "Both players start with 30 health. Reduce your opponent's health to 0 to win.")
            RuleCard (icon: "drop.fill",              iconColor: Color (hex: "1a6fd4"), title: "Mana",              bodyText: "You start with 0 mana. Each turn you gain 1 more — turn 1 gives 1 mana, turn 2 gives 2, up to a cap of 10.")
            RuleCard (icon: "hand.draw.fill",         iconColor: Color (hex: "9B59B6"), title: "Drawing Cards",     bodyText: "Both players start with 4 cards. You draw 1 card at the start of each turn.")
            RuleCard (icon: "rectangle.stack.fill",   iconColor: Color (hex: "FFD700"), title: "Playing Cards",     bodyText: "You can play as many cards as you can afford with your mana each turn.")

            Text ("How You Win")
                .font (.system (size: 18, weight: .heavy))
                .foregroundColor (.white)
                .padding (.top, 16)
                .padding (.bottom, 4)

            RuleCard (icon: "shield.slash.fill",                          iconColor: .orange,                   title: "Attack the Hero",        bodyText: "You can only attack your opponent's health directly if they have no creatures on the board.")
            RuleCard (icon: "figure.stand.line.dotted.figure.stand",      iconColor: Color (hex: "CD7F32"),     title: "Clear the Board First",  bodyText: "If your opponent has creatures, you must attack them first — they block damage from reaching the hero.")
        }
    }
}

// MARK: - CardTypesSection
/// Describes the three categories of card a player will encounter:
/// Creatures (the catch-all for Heroes, Monsters, and Gods on the board),
/// Spells (instant effects), and Gods (the premium creature tier).
///
/// Uses `CardTypeBlock` panels so each type has a distinct visual identity
/// matching the colours used on the actual cards in play.
struct CardTypesSection: View {
    var body: some View {
        VStack (alignment: .leading, spacing: 14) {
            SectionTitle (text: "Card Types")

            CardTypeBlock (
                title: "Creatures",
                subtitle: "Gods, Heroes & Monsters",
                color: Color (hex: "CD7F32"),
                icon: "person.fill",
                bullets: [
                    "Placed onto the board when played",
                    "Have Attack / Health stats — e.g. 3/4 means 3 attack and 4 health",
                    "Can attack once per turn",
                    "Absorb damage before it reaches your hero",
                    "Destroyed when their health reaches 0"
                ]
            )

            CardTypeBlock (
                title: "Spells",
                subtitle: "One-time effects",
                color: Color (hex: "9B59B6"),
                icon: "wand.and.stars",
                bullets: [
                    "Resolve immediately when played — no board placement",
                    "Can deal damage, heal, buff creatures, destroy enemies, and more",
                    "No attack or health stats, just a powerful effect",
                    "Discarded after use"
                ]
            )

            CardTypeBlock (
                title: "Gods",
                subtitle: "Powerful rare creatures",
                color: Color (hex: "FFD700"),
                icon: "sparkles",
                bullets: [
                    "A special tier of creature with higher mana costs (5+)",
                    "Have attack and health stats like other creatures",
                    "Each god has a unique passive or activated divine ability",
                    "The most powerful cards in the game — worth saving mana for"
                ]
            )
        }
    }
}

// MARK: - YourTurnSection
/// Walks the player through the five phases of a turn in numbered order,
/// followed by three "keep in mind" rules covering summoning sickness,
/// attack limits, and how combat damage works.
///
/// The step-by-step panel uses a distinct frosted background and border to
/// visually separate it from the `RuleCard` entries below, making the
/// sequential turn order easy to scan at a glance.
struct YourTurnSection: View {
    var body: some View {
        VStack (alignment: .leading, spacing: 14) {
            SectionTitle (text: "A Turn Looks Like")

            VStack (spacing: 10) {
                StepRow (number: 1, text: "Draw a card from your deck")
                StepRow (number: 2, text: "Gain mana for this turn")
                StepRow (number: 3, text: "Play any cards you can afford — creatures go to the board, spells resolve immediately")
                StepRow (number: 4, text: "Attack with your creatures — each can attack one enemy creature, or the opponent directly if their board is empty")
                StepRow (number: 5, text: "End your turn — your opponent goes next")
            }
            .padding (16)
            .background (Color.white.opacity (0.04))
            .cornerRadius (12)
            .overlay (
                RoundedRectangle (cornerRadius: 12)
                    .stroke (Color.red.opacity (0.2), lineWidth: 1)
            )

            Text ("Keep in Mind")
                .font (.system (size: 18, weight: .heavy))
                .foregroundColor (.white)
                .padding (.top, 8)
                .padding (.bottom, 4)

            RuleCard (icon: "clock.fill",                iconColor: .orange,               title: "Summoning Sickness",       bodyText: "Most creatures can't attack the turn they're played — they must wait until your next turn. Perseus is an exception.")
            RuleCard (icon: "bolt.fill",                  iconColor: Color (hex: "FFD700"), title: "One Attack Per Creature",   bodyText: "Each creature can only attack once per turn, so choose your targets wisely.")
            RuleCard (icon: "arrow.left.arrow.right",     iconColor: Color (hex: "1a6fd4"), title: "Combat Damage",             bodyText: "When two creatures fight, both take damage equal to the other's attack. Both can die in a single trade.")
        }
    }
}

// MARK: - TheDeckSection
/// Describes the shared card pool — total card count, type distribution,
/// and a proportional bar chart visualising the breakdown.
///
/// The bar chart uses `GeometryReader` to make each bar's filled width
/// proportional to the container rather than fixed in points, so the chart
/// scales correctly on all device sizes. Each bar's fill width is calculated
/// as `(count / totalCards) * containerWidth`.
struct TheDeckSection: View {

    /// The total number of cards in the shared deck.
    /// Used as the denominator for the proportional bar chart so bars
    /// accurately reflect each type's share of the full pool.
    private let totalCards: Int = 28

    /// The deck's type distribution, each entry carrying a display label,
    /// card count, and accent colour matching the card type's visual identity.
    ///
    /// Counts: 6 Gods + 6 Heroes + 6 Monsters + 10 Spells = 28 cards total.
    let segments: [(String, Int, Color)] = [
        ("Spells",   10, Color (hex: "9B59B6")),
        ("Monsters",  6, Color (hex: "CD7F32")),
        ("Heroes",    6, Color (hex: "C0C0C0")),
        ("Gods",      6, Color (hex: "FFD700"))
    ]

    var body: some View {
        VStack (alignment: .leading, spacing: 14) {
            SectionTitle (text: "The Deck")

            RuleCard (icon: "rectangle.stack.fill", iconColor: .red,    title: "28 Cards Total",     bodyText: "Both players draw from the same shared pool of 28 cards.")
            RuleCard (icon: "shuffle",              iconColor: .orange, title: "Deck Composition",   bodyText: "6 monsters, 6 heroes, 6 gods, and 10 spells — enough variety without being overwhelming.")

            // MARK: Bar Chart
            // Each bar's filled width is `(count / totalCards) * availableWidth`.
            // `GeometryReader` provides `availableWidth` at runtime so the chart
            // is fully responsive — no hardcoded point values.
            VStack (alignment: .leading, spacing: 10) {
                Text ("Deck Breakdown")
                    .font (.system (size: 15, weight: .bold))
                    .foregroundColor (.white)

                ForEach (segments, id: \.0) { label, count, color in
                    HStack (spacing: 10) {
                        // Type label — fixed width so all bars start at the same x position.
                        Text (label)
                            .font (.system (size: 13, weight: .semibold))
                            .foregroundColor (color)
                            .frame (width: 68, alignment: .leading)

                        GeometryReader { geo in
                            ZStack (alignment: .leading) {
                                // Track: full-width empty bar.
                                RoundedRectangle (cornerRadius: 4)
                                    .fill (Color.white.opacity (0.07))
                                // Fill: proportional to this type's share of the total pool.
                                RoundedRectangle (cornerRadius: 4)
                                    .fill (color.opacity (0.7))
                                    .frame (width: geo.size.width * CGFloat (count) / CGFloat (totalCards))
                            }
                        }
                        .frame (height: 18)

                        // Numeric count label to the right of each bar.
                        Text ("\(count)")
                            .font (.system (size: 13, weight: .bold))
                            .foregroundColor (.white.opacity (0.6))
                            .frame (width: 20)
                    }
                }
            }
            .padding (16)
            .background (Color.white.opacity (0.04))
            .cornerRadius (12)
            .overlay (
                RoundedRectangle (cornerRadius: 12)
                    .stroke (Color.white.opacity (0.1), lineWidth: 1)
            )
            .padding (.top, 4)
        }
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        HowToPlayView ()
    }
}
