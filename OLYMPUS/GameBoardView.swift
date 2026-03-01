import SwiftUI

// MARK: - GameBoardView
/// The primary game screen, composing all in-game UI sub-views into a single
/// full-screen layout for both single-player (VS AI) and local multiplayer modes.
///
/// The board is split into five vertically stacked regions:
/// ```
/// ┌─────────────────────────┐
/// │      OpponentAreaView   │  ← opponent stats, face-down hand, board creatures
/// ├─────────────────────────┤
/// │    BattlefieldDivider   │  ← turn indicator + scrolling game message
/// ├─────────────────────────┤
/// │      PlayerAreaView     │  ← player board creatures + stats
/// ├─────────────────────────┤
/// │      PlayerHandView     │  ← scrollable hand of playable cards
/// ├─────────────────────────┤
/// │      ControlBarView     │  ← Quit / Attack Hero / End Turn + context hints
/// └─────────────────────────┘
/// ```
///
/// Modal overlays are rendered on top of the board stack via ZStack layering:
/// - `GameOverOverlay` — shown when `game.gameResult` is no longer `.ongoing`.
/// - `CardPickerOverlay` — shown for targeting modes that require the player to
///   choose from a subset of cards (Odysseus, Necromancy).
///
/// `GameState` is owned here as a `@StateObject` and passed down to sub-views as
/// an `@ObservedObject` reference. This ensures a single source of truth for all
/// game logic while allowing every sub-view to react to state changes automatically.
struct GameBoardView: View {

    // MARK: State & Environment

    /// The authoritative game state for this match. Initialised once in `init`
    /// with the selected `GameMode` and retained for the lifetime of this view.
    /// Sub-views observe it directly rather than receiving copied data, so any
    /// mutation (playing a card, attacking, ending a turn) propagates instantly
    /// across all regions of the board.
    @StateObject private var game: GameState

    /// Provides the navigation-stack dismiss action so the Quit button and the
    /// "Main Menu" option on the game-over screen can pop back to `ContentView`
    /// without needing a binding passed down from the parent.
    @Environment(\.dismiss) var dismiss

    // MARK: Initialiser

    /// Initialises `GameState` with the given mode before the view is first rendered.
    /// The `StateObject` wrapper requires the wrappedValue to be set via the
    /// underscore-prefixed stored property (`_game`) rather than the projected
    /// value, which is why this explicit `init` is necessary.
    init (mode: GameMode) {
        _game = StateObject (wrappedValue: GameState (mode: mode))
    }

    // MARK: Body

    var body: some View {
        ZStack {
            // Slightly darker background than the rest of the app (#0a0a0a vs #111111)
            // to make the board feel like a distinct, immersive space.
            Color (hex: "0a0a0a").ignoresSafeArea ()

            // MARK: Board Layout
            // Five sub-views stacked vertically with no spacing so regions share
            // borders cleanly. Each sub-view manages its own internal padding.
            VStack (spacing: 0) {
                OpponentAreaView  (game: game)
                BattlefieldDivider (game: game)
                PlayerAreaView    (game: game)
                PlayerHandView    (game: game)
                ControlBarView    (game: game, dismiss: dismiss)
            }

            // MARK: Game Over Overlay
            // Rendered on top of the entire board when the match ends. The overlay
            // is only added to the view hierarchy when needed — SwiftUI skips it
            // entirely while `gameResult` is `.ongoing`, keeping the render tree lean.
            if game.gameResult != .ongoing {
                GameOverOverlay (game: game, dismiss: dismiss)
            }

            // MARK: Card Picker Overlays
            // Certain card abilities (Odysseus, Necromancy) require the player to
            // choose from a dynamically generated list of cards. A `switch` on
            // `targetingMode` selects the appropriate overlay configuration.
            // All other targeting modes (creature selection, Lightning Bolt) are
            // handled inline on the board itself, so `default` resolves to nothing.
            switch game.targetingMode {
            case .odysseusChoice (let top2, _):
                // Odysseus: player peeks at the top 2 cards of the deck and keeps one.
                CardPickerOverlay (
                    title: "Odysseus — Pick a Card",
                    subtitle: "One goes to your hand. The other is discarded.",
                    cards: top2,
                    onPick: { game.resolveOdysseusChoice ($0) },
                    onCancel: { game.cancelTargeting () }
                )
            case .necromancyChoice (let creatures, _):
                // Necromancy: player selects a creature from their discard pile to revive.
                CardPickerOverlay (
                    title: "Necromancy — Revive a Creature",
                    subtitle: "Pick a creature from your discard pile to bring back.",
                    cards: creatures,
                    onPick: { game.resolveNecromancyChoice ($0) },
                    onCancel: { game.cancelTargeting () }
                )
            default:
                EmptyView ()
            }
        }
        .navigationBarHidden (true)
    }
}

// MARK: - OpponentAreaView
/// Renders everything related to the opponent: their health, mana bar, face-down
/// hand representation, and live board creatures.
///
/// Also handles two targeting modes that require the player to tap an opponent's
/// creature — standard creature-vs-creature combat and Lightning Bolt targeting.
/// The `creatureTapAction` computed property returns the appropriate callback for
/// whichever mode is active, keeping tap-handling logic out of the view body itself.
struct OpponentAreaView: View {
    @ObservedObject var game: GameState

    // MARK: Targeting Helpers

    /// Returns a closure that handles a tap on opponent creature at the given board
    /// index, or `nil` if the current targeting mode doesn't involve opponent creatures.
    /// The view body uses this to decide whether tapping a creature triggers a
    /// targeting resolution or a direct attack.
    var creatureTapAction: ((Int) -> Void)? {
        switch game.targetingMode {
        case .selectingOpponentCreature:
            // A spell requiring a specific enemy target (e.g. Curse of Circe,
            // Sisyphus's Burden) is waiting for the player to pick a creature.
            return { i in game.selectOpponentTarget (boardIndex: i) }
        case .selectingLightningTarget:
            // Lightning Bolt is active — the player can hit a creature or the hero.
            return { i in game.selectLightningTarget (boardIndex: i) }
        default:
            return nil
        }
    }

    /// `true` when any targeting mode that involves opponent creatures is active.
    /// Used to pass the `isAttackTarget` flag to `BoardCreatureView`, which
    /// applies a red highlight and glow to signal that creatures are valid targets.
    var showTargetHighlight: Bool {
        switch game.targetingMode {
        case .selectingOpponentCreature, .selectingLightningTarget: return true
        default: return false
        }
    }

    // MARK: Body

    var body: some View {
        VStack (spacing: 6) {

            // MARK: Opponent Stats Bar
            // Hand count (left), health (centre), mana + bar (right).
            // Mirrored layout to `PlayerAreaView`'s stat bar, with mana on the
            // opposite side so both bars feel symmetric around the battlefield divider.
            HStack {
                // Face-down card count — gives the player imperfect information
                // about the opponent's hand size without revealing card identities.
                HStack (spacing: 4) {
                    Image (systemName: "rectangle.stack.fill")
                        .font (.system (size: 11))
                        .foregroundColor (.white.opacity (0.5))
                    Text ("\(game.opponent.hand.count)")
                        .font (.system (size: 12, weight: .semibold))
                        .foregroundColor (.white.opacity (0.6))
                }
                Spacer ()
                // Opponent health — large and centred so both players can
                // read it at a glance from across the table.
                HStack (spacing: 6) {
                    Image (systemName: "heart.fill")
                        .foregroundColor (.red)
                        .font (.system (size: 14))
                    Text ("\(game.opponent.health)")
                        .font (.system (size: 20, weight: .black))
                        .foregroundColor (.white)
                }
                Spacer ()
                // Mana display with a fill bar. `GeometryReader` is used to make
                // the bar width proportional to the container rather than fixed,
                // so it scales correctly on all device sizes.
                HStack (spacing: 6) {
                    Image (systemName: "drop.fill")
                        .font (.system (size: 10))
                        .foregroundColor (Color (hex: "1a6fd4"))
                    Text ("\(game.opponent.mana)/\(game.opponent.maxMana)")
                        .font (.system (size: 12, weight: .bold))
                        .foregroundColor (Color (hex: "1a6fd4"))
                    GeometryReader { geo in
                        ZStack (alignment: .leading) {
                            RoundedRectangle (cornerRadius: 3)
                                .fill (Color.white.opacity (0.1))
                            RoundedRectangle (cornerRadius: 3)
                                .fill (Color (hex: "1a6fd4"))
                                // Guard against division by zero if maxMana is 0
                                // at the very start of the game before the first turn.
                                .frame (width: game.opponent.maxMana > 0
                                    ? geo.size.width * CGFloat (game.opponent.mana) / CGFloat (game.opponent.maxMana)
                                    : 0)
                        }
                    }
                    .frame (width: 50, height: 7)
                }
            }
            .padding (.horizontal, 16)
            .padding (.top, 8)

            // MARK: Face-Down Hand
            // Renders one small opaque card-back rectangle per card in the
            // opponent's hand. Negative spacing (-8) creates a fanned overlap
            // effect that looks natural and communicates hand size clearly.
            // Card identities remain hidden — only the count is revealed.
            HStack (spacing: -8) {
                ForEach (0..<game.opponent.hand.count, id: \.self) { _ in
                    RoundedRectangle (cornerRadius: 4)
                        .fill (Color (hex: "1a1a2e"))
                        .frame (width: 28, height: 42)
                        .overlay (RoundedRectangle (cornerRadius: 4).stroke (Color.white.opacity (0.2), lineWidth: 1))
                }
            }
            .frame (height: 44)

            // MARK: Opponent Board
            // Horizontally scrollable row of the opponent's live creatures.
            // Each `BoardCreatureView` receives the highlight flag and the
            // resolved tap action so it can display targeting UI and forward taps
            // to the correct game-logic handler.
            ScrollView (.horizontal, showsIndicators: false) {
                HStack (spacing: 8) {
                    if game.opponent.board.isEmpty {
                        Text ("No creatures")
                            .font (.system (size: 12))
                            .foregroundColor (.white.opacity (0.2))
                            .frame (height: 80)
                    } else {
                        ForEach (game.opponent.board.indices, id: \.self) { i in
                            BoardCreatureView (
                                card: game.opponent.board [i],
                                // Highlight all opponent creatures when an attacker is
                                // selected or a targeting mode expects an enemy target.
                                isAttackTarget: game.attackerIndex != nil || showTargetHighlight,
                                isOpponent: true
                            ) {
                                // Priority: spell-targeting actions take precedence.
                                // If no targeting mode is active, check whether an
                                // attacker has already been selected and resolve combat.
                                if let action = creatureTapAction {
                                    action (i)
                                } else if let atk = game.attackerIndex {
                                    game.attackCreature (attackerIdx: atk, defenderIdx: i)
                                }
                            }
                        }
                    }
                }
                .padding (.horizontal, 12)
            }
            .frame (height: 90)
        }
        .frame (maxWidth: .infinity)
        .background (Color.white.opacity (0.02))
    }
}

// MARK: - BattlefieldDivider
/// The horizontal strip between the two halves of the board, displaying whose
/// turn it is and a scrolling game-event message log.
///
/// The turn badge flips between green ("YOUR TURN") and red ("OPPONENT'S TURN")
/// so both players can immediately orient themselves. The message area uses a
/// UUID-keyed `id` modifier to reset the scroll position every time the message
/// changes — without this, a new message that is shorter than the previous one
/// might appear mid-scroll rather than starting from the left.
struct BattlefieldDivider: View {
    @ObservedObject var game: GameState

    /// A new UUID is generated each time `game.message` changes, assigned to the
    /// `Text` via `.id()`. SwiftUI treats a changed `id` as a brand-new view,
    /// which resets the parent `ScrollView`'s content offset to zero — effectively
    /// auto-scrolling to the start of every new message.
    @State private var messageId: UUID = UUID ()

    var body: some View {
        ZStack {
            // Subtle red gradient line that fades to clear at both edges,
            // creating a soft centred glow rather than a hard full-width rule.
            Rectangle ()
                .fill (LinearGradient (colors: [.clear, Color.red.opacity (0.4), .clear], startPoint: .leading, endPoint: .trailing))
                .frame (height: 1)

            HStack (spacing: 10) {
                // Turn indicator badge — green when it's the player's turn for a
                // positive cue, muted red during the opponent's turn.
                Text (game.isPlayerTurn ? "YOUR TURN" : "OPPONENT'S TURN")
                    .font (.system (size: 10, weight: .black))
                    .foregroundColor (game.isPlayerTurn ? .green : .red.opacity (0.8))
                    .padding (.horizontal, 10)
                    .padding (.vertical, 4)
                    .background (
                        RoundedRectangle (cornerRadius: 4)
                            .fill (game.isPlayerTurn ? Color.green.opacity (0.15) : Color.red.opacity (0.1))
                            .overlay (RoundedRectangle (cornerRadius: 4).stroke (game.isPlayerTurn ? Color.green.opacity (0.5) : Color.red.opacity (0.3), lineWidth: 1))
                    )
                    .fixedSize ()

                // Scrolling game message — only rendered when there is content to show.
                // Horizontal scrolling handles long event strings (e.g. "Zeus deals 2
                // damage to all enemy creatures") without truncation or layout shifts.
                if !game.message.isEmpty {
                    ScrollView (.horizontal, showsIndicators: false) {
                        Text (game.message)
                            .font (.system (size: 10))
                            .foregroundColor (.white.opacity (0.55))
                            .fixedSize ()
                            .id (messageId)  // Forces view identity reset on message change.
                    }
                    .frame (maxWidth: .infinity)
                    .onChange (of: game.message) {
                        // Regenerate the ID so SwiftUI discards the old Text view
                        // and creates a fresh one, resetting scroll to the leading edge.
                        messageId = UUID ()
                    }
                }
            }
            .padding (.horizontal, 12)
        }
        .frame (height: 30)
    }
}

// MARK: - PlayerAreaView
/// Renders the player's live board creatures and their stat bar (mana, health,
/// hand count). Mirrors `OpponentAreaView` in structure but with the stat bar
/// below the board and the mana on the left rather than the right.
///
/// Handles the `selectingFriendlyCreature` targeting mode, which is triggered
/// by spells that require the player to choose one of their own creatures as a
/// target (e.g. Shield of Sparta, Prometheus's Fire).
struct PlayerAreaView: View {
    @ObservedObject var game: GameState

    // MARK: Targeting Helpers

    /// Returns a closure for tapping a friendly creature when a spell requiring
    /// a friendly target is active, or `nil` otherwise. This keeps the tap
    /// handler in the view body simple — it just calls the closure if one exists,
    /// or falls through to the attacker-selection logic if not.
    var creatureTapAction: ((Int) -> Void)? {
        switch game.targetingMode {
        case .selectingFriendlyCreature:
            return { i in game.selectFriendlyTarget (boardIndex: i) }
        default:
            return nil
        }
    }

    /// `true` when the `selectingFriendlyCreature` targeting mode is active,
    /// used to pass the `isSelected` highlight flag to every `BoardCreatureView`
    /// so the player knows all friendly creatures are valid targets.
    var showFriendlyHighlight: Bool {
        if case .selectingFriendlyCreature = game.targetingMode { return true }
        return false
    }

    // MARK: Body

    var body: some View {
        VStack (spacing: 6) {

            // MARK: Player Board
            // Horizontally scrollable row of the player's live creatures.
            // Tapping a creature either: resolves a pending friendly-target spell,
            // deselects the current attacker (toggle), or selects a new attacker.
            ScrollView (.horizontal, showsIndicators: false) {
                HStack (spacing: 8) {
                    if game.player.board.isEmpty {
                        Text ("No creatures — play cards from your hand")
                            .font (.system (size: 12))
                            .foregroundColor (.white.opacity (0.2))
                            .frame (height: 80)
                    } else {
                        ForEach (game.player.board.indices, id: \.self) { i in
                            BoardCreatureView (
                                card: game.player.board [i],
                                // Highlight if this creature is the selected attacker,
                                // or if a friendly-targeting spell wants any creature.
                                isSelected: game.attackerIndex == i || showFriendlyHighlight,
                                isAttackTarget: false,
                                isOpponent: false
                            ) {
                                if let action = creatureTapAction {
                                    // A friendly-targeting spell is waiting — resolve it.
                                    action (i)
                                } else if game.isPlayerTurn {
                                    // Toggle attacker selection: deselect if tapping the
                                    // already-selected creature, otherwise select the new one.
                                    if game.attackerIndex == i {
                                        game.attackerIndex = nil
                                    } else {
                                        game.selectAttacker (at: i)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding (.horizontal, 12)
            }
            .frame (height: 90)

            // MARK: Player Stats Bar
            // Mana (left), health (centre), hand count (right).
            HStack {
                // Mana display with proportional fill bar, mirroring the opponent's
                // mana bar but on the left side and slightly larger for readability.
                HStack (spacing: 6) {
                    Image (systemName: "drop.fill")
                        .font (.system (size: 12))
                        .foregroundColor (Color (hex: "1a6fd4"))
                    Text ("\(game.player.mana)/\(game.player.maxMana)")
                        .font (.system (size: 14, weight: .black))
                        .foregroundColor (Color (hex: "1a6fd4"))
                    GeometryReader { geo in
                        ZStack (alignment: .leading) {
                            RoundedRectangle (cornerRadius: 3)
                                .fill (Color.white.opacity (0.1))
                            RoundedRectangle (cornerRadius: 3)
                                .fill (Color (hex: "1a6fd4"))
                                .frame (width: game.player.maxMana > 0
                                    ? geo.size.width * CGFloat (game.player.mana) / CGFloat (game.player.maxMana)
                                    : 0)
                        }
                    }
                    .frame (width: 60, height: 8)
                }
                Spacer ()
                HStack (spacing: 6) {
                    Image (systemName: "heart.fill")
                        .foregroundColor (.red)
                        .font (.system (size: 14))
                    Text ("\(game.player.health)")
                        .font (.system (size: 20, weight: .black))
                        .foregroundColor (.white)
                }
                Spacer ()
                HStack (spacing: 4) {
                    Image (systemName: "rectangle.stack.fill")
                        .font (.system (size: 11))
                        .foregroundColor (.white.opacity (0.5))
                    Text ("\(game.player.hand.count)")
                        .font (.system (size: 12, weight: .semibold))
                        .foregroundColor (.white.opacity (0.6))
                }
            }
            .padding (.horizontal, 16)
            .padding (.bottom, 6)
        }
        .frame (maxWidth: .infinity)
        .background (Color.white.opacity (0.02))
    }
}

// MARK: - PlayerHandView
/// A horizontally scrollable strip displaying the player's current hand of cards.
///
/// Tap behaviour follows a two-tap-to-play pattern for safety:
/// 1. First tap selects the card (highlights it, deselects any active attacker).
/// 2. Second tap on the same card plays it from hand.
///
/// If a targeting mode is active when the player taps a hand card, the tap
/// cancels targeting instead of selecting a card — this prevents accidental
/// card plays while a spell is waiting for a target.
///
/// Each card is evaluated for playability against the player's current mana,
/// passing `isPlayable` to `CardView` so unaffordable cards render at reduced
/// opacity without disabling tap detection at this level.
struct PlayerHandView: View {
    @ObservedObject var game: GameState

    var body: some View {
        ScrollView (.horizontal, showsIndicators: false) {
            HStack (spacing: 8) {
                ForEach (game.player.hand.indices, id: \.self) { i in
                    let card = game.player.hand [i]
                    let isSelected = game.selectedCardIndex == i

                    // Resolve effective mana cost, accounting for reductions from
                    // cards like Medea ("Spells cost 1 less mana").
                    let cost = game.player.effectiveManaCost (card)
                    let isPlayable = game.isPlayerTurn && game.player.mana >= cost

                    ZStack {
                        // White blur halo behind the selected card provides an
                        // additional glow layer on top of `CardView`'s own selection
                        // border, making the chosen card unmistakeable in a crowded hand.
                        if isSelected {
                            RoundedRectangle (cornerRadius: 10)
                                .stroke (Color.white, lineWidth: 2.5)
                                .blur (radius: 4)
                                .opacity (0.6)
                        }
                        CardView (card: card, isSelected: isSelected, isPlayable: isPlayable)
                    }
                    .onTapGesture {
                        guard game.isPlayerTurn else { return }

                        // If any targeting mode is active, cancel it rather than
                        // selecting a card — the player likely tapped by mistake.
                        if case .none = game.targetingMode {
                        } else {
                            game.cancelTargeting ()
                            return
                        }

                        if isSelected {
                            // Second tap on the already-selected card: attempt to play it.
                            game.playCardFromHand (at: i)
                        } else {
                            // First tap: select this card and clear any attacker selection
                            // so the two selection states don't conflict.
                            game.selectedCardIndex = i
                            game.attackerIndex = nil
                        }
                    }
                }
            }
            .padding (.horizontal, 12)
            .padding (.vertical, 16)
        }
        .frame (height: 220)
        .background (Color (hex: "111111"))
    }
}

// MARK: - ControlBarView
/// The bottom action bar, providing the player with global game actions and
/// contextual hints that adapt to the current targeting state.
///
/// Contains up to four elements depending on game state:
/// - **Quit** — always visible; returns to the main menu immediately.
/// - **Attack Hero** — appears when an attacker is selected and the opponent's
///   board is empty (the only time direct hero attacks are legal).
/// - **Bolt Hero** — appears during Lightning Bolt targeting as an alternative
///   to hitting a creature, allowing the spell to target the opponent directly.
/// - **End Turn** — always visible on the right; disabled and relabelled
///   "Waiting..." when it is not the player's turn.
///
/// A `contextHint` view builder in the centre of the bar provides one-line
/// instructions that update with each targeting mode change, reducing the need
/// for players to memorise interaction rules.
struct ControlBarView: View {
    @ObservedObject var game: GameState
    var dismiss: DismissAction

    /// `true` when the Lightning Bolt spell is waiting for the player to pick
    /// a target — used to conditionally show the "Bolt Hero" button.
    var isLightningTargeting: Bool {
        if case .selectingLightningTarget = game.targetingMode { return true }
        return false
    }

    // MARK: Body

    var body: some View {
        HStack (spacing: 10) {

            // MARK: Quit Button
            // Immediately dismisses the game view and returns to the main menu.
            // Intentionally low-contrast so it doesn't compete visually with the
            // End Turn button on the opposite side.
            Button (action: { dismiss () }) {
                HStack (spacing: 5) {
                    Image (systemName: "xmark").font (.system (size: 12, weight: .bold))
                    Text ("Quit").font (.system (size: 13, weight: .semibold))
                }
                .foregroundColor (.white.opacity (0.6))
                .padding (.horizontal, 12)
                .padding (.vertical, 10)
                .background (Color.white.opacity (0.07))
                .cornerRadius (8)
                .overlay (RoundedRectangle (cornerRadius: 8).stroke (Color.white.opacity (0.15), lineWidth: 1))
            }

            // MARK: Attack Hero Button
            // Only shown when: (a) an attacker is selected, AND (b) the opponent
            // has no creatures. This enforces the game rule that the hero can only
            // be attacked directly when the board is clear, without requiring the
            // player to know that rule in advance.
            if game.attackerIndex != nil && game.opponent.board.isEmpty {
                Button (action: {
                    if let atk = game.attackerIndex { game.attackHero (attackerIdx: atk) }
                }) {
                    HStack (spacing: 5) {
                        Image (systemName: "bolt.fill").font (.system (size: 12))
                        Text ("Attack Hero").font (.system (size: 13, weight: .semibold))
                    }
                    .foregroundColor (.white)
                    .padding (.horizontal, 12)
                    .padding (.vertical, 10)
                    .background (Color.orange.opacity (0.3))
                    .cornerRadius (8)
                    .overlay (RoundedRectangle (cornerRadius: 8).stroke (Color.orange, lineWidth: 1.5))
                }
            }

            // MARK: Bolt Hero Button
            // Only shown during Lightning Bolt targeting. Filled gold (the spell
            // colour) rather than outlined to make it stand out clearly as the
            // alternative to picking a creature target.
            if isLightningTargeting {
                Button (action: { game.selectLightningTarget (targetHero: true) }) {
                    HStack (spacing: 5) {
                        Image (systemName: "bolt.fill").font (.system (size: 12))
                        Text ("Bolt Hero").font (.system (size: 13, weight: .semibold))
                    }
                    .foregroundColor (.black)
                    .padding (.horizontal, 12)
                    .padding (.vertical, 10)
                    .background (Color (hex: "FFD700"))
                    .cornerRadius (8)
                }
            }

            Spacer ()

            // MARK: Context Hint
            // A one-line instruction rendered in the centre of the bar. Updates
            // automatically as `targetingMode` and selection state change,
            // guiding the player through multi-step interactions without UI clutter.
            contextHint

            Spacer ()

            // MARK: End Turn Button
            // Relabelled and visually dimmed when it is not the player's turn,
            // and `.disabled` to block accidental taps during the opponent's turn.
            Button (action: {
                guard game.isPlayerTurn else { return }
                game.endTurn ()
            }) {
                HStack (spacing: 5) {
                    Text (game.isPlayerTurn ? "End Turn" : "Waiting...")
                        .font (.system (size: 14, weight: .bold))
                    if game.isPlayerTurn {
                        Image (systemName: "arrow.right.circle.fill").font (.system (size: 14))
                    }
                }
                .foregroundColor (game.isPlayerTurn ? .white : .white.opacity (0.3))
                .padding (.horizontal, 14)
                .padding (.vertical, 10)
                .background (game.isPlayerTurn ? Color.red.opacity (0.3) : Color.white.opacity (0.05))
                .cornerRadius (8)
                .overlay (RoundedRectangle (cornerRadius: 8).stroke (game.isPlayerTurn ? Color.red : Color.white.opacity (0.1), lineWidth: 1.5))
            }
            .disabled (!game.isPlayerTurn)
        }
        .padding (.horizontal, 12)
        .padding (.vertical, 10)
        .background (Color (hex: "0d0d0d"))
    }

    // MARK: Context Hint Builder

    /// Produces a short instructional label based on the current game interaction
    /// state. `@ViewBuilder` allows different `Text` views and `EmptyView` to be
    /// returned from the same property without needing an `AnyView` type-erasure wrapper.
    @ViewBuilder var contextHint: some View {
        switch game.targetingMode {
        case .none:
            // No targeting active — hint depends on what the player has selected.
            if game.selectedCardIndex != nil {
                Text ("Tap again to play").font (.system (size: 11)).foregroundColor (.white.opacity (0.5))
            } else if game.attackerIndex != nil {
                Text (game.opponent.board.isEmpty ? "Tap Attack Hero" : "Tap a target")
                    .font (.system (size: 11)).foregroundColor (.orange.opacity (0.8))
            }
        case .selectingFriendlyCreature:
            Text ("Pick your creature").font (.system (size: 11)).foregroundColor (.green.opacity (0.9))
        case .selectingOpponentCreature:
            Text ("Pick enemy creature").font (.system (size: 11)).foregroundColor (.red.opacity (0.9))
        case .selectingLightningTarget:
            Text ("Tap creature or Bolt Hero").font (.system (size: 11)).foregroundColor (Color (hex: "FFD700"))
        default:
            EmptyView ()
        }
    }
}

// MARK: - BoardCreatureView
/// A compact card representation used exclusively for creatures on the battlefield
/// (both player and opponent boards).
///
/// Distinct from `CardView` in two key ways:
/// 1. **Fixed 64×64 pt artwork square** with name and stats below — much smaller
///    than the full card, optimised for the limited board space.
/// 2. **Three visual states** driven by `isSelected` and `isAttackTarget`:
///    - **Neutral** — type-coloured border, no overlay.
///    - **Selected** (green) — player's chosen attacker, or a valid friendly target.
///    - **Attack target** (red) — valid enemy target, with a semi-transparent
///      red overlay on the artwork to reinforce the danger.
///
/// Summoning sickness is visualised by a dark overlay on the artwork for the
/// player's own creatures (`!card.canAttack && !isOpponent`). Opponent creatures
/// never show this overlay because the player does not need to track their
/// readiness state.
struct BoardCreatureView: View {
    let card: Card

    /// `true` when this creature is the active attacker or a valid friendly target.
    /// Renders a green border and glow.
    var isSelected: Bool = false

    /// `true` when this creature is a valid attack or spell target.
    /// Renders a red border, glow, and semi-transparent red overlay.
    var isAttackTarget: Bool = false

    /// `true` for opponent creatures. Suppresses the summoning-sickness overlay
    /// since readiness of enemy creatures is not information the player can act on.
    var isOpponent: Bool = false

    /// Callback fired when the player taps this creature. The parent view
    /// resolves the appropriate game-logic action (select attacker, resolve
    /// targeting, attack) based on current game state.
    let onTap: () -> Void

    // MARK: Computed Properties

    /// Resolves the border colour based on interaction state.
    /// Priority: selected (green) > attack target (red) > type default colour.
    var borderColor: Color {
        if isSelected    { return .green }
        if isAttackTarget { return .red }
        return Color (hex: card.type.borderColors [0])
    }

    // MARK: Body

    var body: some View {
        VStack (spacing: 3) {
            ZStack {
                // Type-tinted near-black background, consistent with `CardView`.
                RoundedRectangle (cornerRadius: 8)
                    .fill (cardBackground)
                    .frame (width: 64, height: 64)

                // Artwork or SF Symbol fallback, matching the approach in `CardView`.
                if UIImage (named: card.imageName) != nil {
                    Image (card.imageName)
                        .interpolation (.none)
                        .resizable ()
                        .scaledToFill ()
                        .frame (width: 64, height: 64)
                        .clipShape (RoundedRectangle (cornerRadius: 8))
                } else {
                    Image (systemName: placeholderIcon)
                        .font (.system (size: 24))
                        .foregroundColor (Color (hex: card.type.borderColors [0]).opacity (0.6))
                        .frame (width: 64, height: 64)
                }

                // Summoning sickness overlay — applied only to the player's own
                // creatures that cannot yet attack. The dark wash communicates
                // "not ready" without requiring a separate icon or label.
                if !card.canAttack && !isOpponent {
                    RoundedRectangle (cornerRadius: 8)
                        .fill (Color.black.opacity (0.45))
                        .frame (width: 64, height: 64)
                }

                // Attack-target overlay — a red tint on the artwork reinforces
                // the border and glow, making valid targets immediately obvious
                // even in a densely packed board row.
                if isAttackTarget {
                    RoundedRectangle (cornerRadius: 8)
                        .fill (Color.red.opacity (0.2))
                        .frame (width: 64, height: 64)
                }
            }
            // Border stroke and drop shadow both respond to interaction state,
            // creating a cohesive multi-layer highlight effect.
            .overlay (
                RoundedRectangle (cornerRadius: 8)
                    .stroke (borderColor, lineWidth: isSelected || isAttackTarget ? 2.5 : 1.5)
            )
            .shadow (color: isSelected ? Color.green.opacity (0.6) : (isAttackTarget ? Color.red.opacity (0.6) : .clear), radius: 8)

            // Card name below the artwork — single line, clipped if too long.
            Text (card.name)
                .font (.system (size: 8, weight: .bold))
                .foregroundColor (.white)
                .lineLimit (1)
                .frame (width: 64)

            // Live attack and health stats — uses `currentAttack` and `currentHealth`
            // so buffs and damage dealt mid-game are reflected immediately on the token.
            HStack (spacing: 6) {
                HStack (spacing: 2) {
                    Image (systemName: "bolt.fill").font (.system (size: 7)).foregroundColor (.orange)
                    Text ("\(card.currentAttack ?? 0)").font (.system (size: 10, weight: .black)).foregroundColor (.orange)
                }
                HStack (spacing: 2) {
                    Image (systemName: "heart.fill").font (.system (size: 7)).foregroundColor (.red)
                    Text ("\(card.currentHealth ?? 0)").font (.system (size: 10, weight: .black)).foregroundColor (.red)
                }
            }
        }
        .onTapGesture { onTap () }
    }

    // MARK: Helpers

    /// Near-black type-tinted background, consistent with `CardView.cardBackground`.
    var cardBackground: Color {
        switch card.type {
        case .god:     return Color (hex: "1a1400")
        case .hero:    return Color (hex: "0d0d0d")
        case .monster: return Color (hex: "120800")
        case .spell:   return Color (hex: "0d0014")
        }
    }

    /// SF Symbol fallback icon, consistent with `CardView.placeholderIcon`.
    var placeholderIcon: String {
        switch card.type {
        case .god:     return "sparkles"
        case .hero:    return "person.fill"
        case .monster: return "flame.fill"
        case .spell:   return "wand.and.stars"
        }
    }
}

// MARK: - CardPickerOverlay
/// A modal overlay that presents a horizontal scrollable list of cards for the
/// player to choose from, used by abilities that require selecting a specific card.
///
/// Currently used by two card abilities:
/// - **Odysseus** — pick one of the top 2 cards from the deck to add to hand.
/// - **Necromancy** — pick a creature from the discard pile to revive.
///
/// The overlay is fully generic — it receives its title, subtitle, card list,
/// and resolution callbacks from the caller, making it straightforward to
/// support additional card-choice abilities in the future without any changes
/// to this component.
struct CardPickerOverlay: View {
    let title: String
    let subtitle: String

    /// The subset of cards the player must choose from.
    let cards: [Card]

    /// Called with the chosen card when the player taps one.
    let onPick: (Card) -> Void

    /// Called if the player taps Cancel, restoring the board to its previous state.
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Heavy scrim darkens the board without completely hiding it, keeping
            // the player aware of the game state while making the overlay the
            // clear focus of attention.
            Color.black.opacity (0.82).ignoresSafeArea ()

            VStack (spacing: 20) {
                // Ability name and instruction text.
                VStack (spacing: 6) {
                    Text (title)
                        .font (.system (size: 20, weight: .heavy))
                        .foregroundColor (.white)
                    Text (subtitle)
                        .font (.system (size: 13))
                        .foregroundColor (.white.opacity (0.6))
                        .multilineTextAlignment (.center)
                }

                // Horizontally scrollable row of full `CardView` instances.
                // Reusing `CardView` here ensures the picker cards look identical
                // to cards in hand, so the player can read all stats before choosing.
                ScrollView (.horizontal, showsIndicators: false) {
                    HStack (spacing: 14) {
                        ForEach (cards) { card in
                            CardView (card: card)
                                .onTapGesture { onPick (card) }
                        }
                    }
                    .padding (.horizontal, 16)
                }

                Button ("Cancel") { onCancel () }
                    .font (.system (size: 14, weight: .semibold))
                    .foregroundColor (.white.opacity (0.6))
                    .padding (.horizontal, 24)
                    .padding (.vertical, 10)
                    .background (Color.white.opacity (0.07))
                    .cornerRadius (8)
                    .overlay (RoundedRectangle (cornerRadius: 8).stroke (Color.white.opacity (0.2), lineWidth: 1))
            }
            .padding (24)
            .background (
                RoundedRectangle (cornerRadius: 20)
                    .fill (Color (hex: "111111"))
                    .overlay (RoundedRectangle (cornerRadius: 20).stroke (Color.red.opacity (0.4), lineWidth: 1.5))
            )
            .padding (20)
        }
    }
}

// MARK: - GameOverOverlay
/// A full-screen modal displayed when the match ends, showing the outcome and
/// offering the player two options: rematch or return to the main menu.
///
/// The "Play Again" button performs an in-place game reset by mutating
/// `GameState` properties directly rather than creating a new `GameState` instance.
/// This approach avoids reinitialising the `@StateObject` in `GameBoardView`
/// (which SwiftUI does not support mid-lifecycle) while fully resetting all
/// match state: players, turn counter, hand, board, log, and targeting mode.
struct GameOverOverlay: View {
    @ObservedObject var game: GameState
    var dismiss: DismissAction

    var body: some View {
        ZStack {
            Color.black.opacity (0.75).ignoresSafeArea ()
            VStack (spacing: 24) {

                // MARK: Result Headline
                // Gold for victory, red for defeat — colours that carry immediate
                // emotional weight and are consistent with the app's god/danger palette.
                Text (game.gameResult == .playerWon ? "VICTORY" : "DEFEAT")
                    .font (.system (size: 56, weight: .heavy))
                    .foregroundColor (game.gameResult == .playerWon ? Color (hex: "FFD700") : .red)
                    .shadow (color: game.gameResult == .playerWon ? Color (hex: "FFD700").opacity (0.6) : Color.red.opacity (0.6), radius: 20)

                // Thematic flavour text reinforcing the mythological setting.
                Text (game.gameResult == .playerWon ? "The gods smile upon you." : "You have fallen in battle.")
                    .font (.system (size: 16))
                    .foregroundColor (.white.opacity (0.7))

                HStack (spacing: 16) {

                    // MARK: Play Again
                    // Resets every piece of mutable game state and calls `setupGame()`
                    // to reshuffle the deck and deal opening hands, effectively
                    // starting a fresh match within the same view hierarchy.
                    Button ("Play Again") {
                        game.gameResult      = .ongoing
                        game.player          = Player (isHuman: true)
                        game.opponent        = Player (isHuman: game.mode == .vsHuman)
                        game.currentTurn     = 1
                        game.isPlayerTurn    = true
                        game.selectedCardIndex = nil
                        game.attackerIndex   = nil
                        game.message         = ""
                        game.gameLog         = []
                        game.targetingMode   = .none
                        game.setupGame ()
                    }
                    .font (.system (size: 15, weight: .bold))
                    .foregroundColor (.white)
                    .padding (.horizontal, 24).padding (.vertical, 12)
                    .background (Color.red.opacity (0.3)).cornerRadius (10)
                    .overlay (RoundedRectangle (cornerRadius: 10).stroke (Color.red, lineWidth: 1.5))

                    // MARK: Main Menu
                    // Calls the SwiftUI dismiss action to pop back to `ContentView`.
                    Button ("Main Menu") { dismiss () }
                        .font (.system (size: 15, weight: .bold))
                        .foregroundColor (.white.opacity (0.7))
                        .padding (.horizontal, 24).padding (.vertical, 12)
                        .background (Color.white.opacity (0.07)).cornerRadius (10)
                        .overlay (RoundedRectangle (cornerRadius: 10).stroke (Color.white.opacity (0.2), lineWidth: 1))
                }
            }
            .padding (40)
            .background (
                RoundedRectangle (cornerRadius: 20)
                    .fill (Color (hex: "111111"))
                    .overlay (RoundedRectangle (cornerRadius: 20).stroke (Color.red.opacity (0.3), lineWidth: 1.5))
            )
            .padding (32)
        }
    }
}

// MARK: - Preview
#Preview {
    GameBoardView (mode: .vsAI)
}
