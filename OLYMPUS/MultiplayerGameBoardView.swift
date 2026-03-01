import SwiftUI

// MARK: - MultiplayerGameBoardView
/// The game board screen for a live online match between two human players.
///
/// Structurally mirrors `GameBoardView` (the VS AI board) but with a fundamental
/// architectural difference: **no game logic is resolved locally**. Every player
/// action — playing a card, attacking, ending a turn — is serialised into an
/// `MPGameAction` and sent to `MultiplayerManager`, which forwards it to Firebase.
/// The authoritative game state lives in `MPGameSnapshot`, which both clients
/// observe in real time. This ensures both players always see an identical board.
///
/// ## Data flow
/// ```
/// Player tap
///     → MPGameAction sent via manager.sendAction(_:)
///         → Firebase Realtime Database
///             → MPGameSnapshot updated
///                 → Both clients re-render via @ObservedObject
/// ```
///
/// ## View decomposition
/// Unlike `GameBoardView` (which uses dedicated sub-view structs), the five board
/// regions here are implemented as computed `some View` properties on the main
/// struct. This keeps all targeting state — which must be shared across regions —
/// in a single scope without threading it through sub-view initialisers.
///
/// ## Perspective helpers
/// `me` and `them` are computed properties that resolve the correct `MPPlayer`
/// based on whether this client is the host or the guest, so the rest of the view
/// never has to branch on `isHost` to decide whose data to render.
struct MultiplayerGameBoardView: View {

    // MARK: Inputs

    /// The Firebase-backed manager that owns the connection, turn authority,
    /// and action dispatch pipeline. Observed so the view re-renders whenever
    /// the game snapshot or turn state changes.
    @ObservedObject var manager: MultiplayerManager

    /// The snapshot captured at the moment the match was confirmed, used as a
    /// fallback while `manager.gameSnapshot` has not yet produced its first update.
    /// Prevents a blank board flash on first render.
    let initialSnapshot: MPGameSnapshot

    // MARK: Environment & Local State

    /// Used by the Quit button and the game-over overlay's "Main Menu" button
    /// to pop back to the navigation stack without a binding.
    @Environment(\.dismiss) var dismiss

    /// Index of the card currently selected in the local player's hand.
    /// Kept local (not synced) because card selection is purely a UI affordance —
    /// the action only becomes network-relevant when the player commits to playing.
    @State private var selectedCardIndex: Int? = nil

    /// Board index of the creature the local player has chosen as their attacker.
    /// Also kept local for the same reason as `selectedCardIndex`.
    @State private var attackerIndex: Int? = nil

    /// The current targeting mode, driven by cards that require a follow-up
    /// selection before their action is dispatched (e.g. Lightning Bolt,
    /// Prometheus's Fire, Odysseus). Resolved locally then dispatched as a single
    /// `MPGameAction` so the network only sees completed decisions, not intermediate state.
    @State private var targetingMode: MPTargetingMode = .none

    /// The last game event string shown in the divider message bar.
    /// Copied from `snapshot.message` on change so it persists for one full
    /// render cycle even if the snapshot updates faster than the UI can display it.
    @State private var localMessage: String = ""

    /// A UUID regenerated every time `localMessage` changes, used as a SwiftUI
    /// view identity key to reset the horizontal scroll position of the message
    /// bar — the same technique used in `BattlefieldDivider` in the single-player board.
    @State private var messageId: UUID = UUID ()

    // MARK: - MPTargetingMode
    /// A local mirror of `TargetingMode` from `GameState`, scoped to this view.
    ///
    /// Defined here rather than shared with `GameState` because the multiplayer
    /// board resolves targeting differently: instead of calling game-logic methods
    /// directly, it constructs and dispatches `MPGameAction` values. Having a
    /// separate enum keeps the two code paths independent and prevents accidental
    /// coupling between the local and networked game engines.
    enum MPTargetingMode {
        /// No pending targeting decision — the idle state.
        case none
        /// A spell targeting a single opponent creature is waiting for selection.
        case selectingOpponentCreature (spell: String, cardIndex: Int)
        /// A spell targeting a friendly creature is waiting for selection.
        case selectingFriendlyCreature (spell: String, cardIndex: Int)
        /// Lightning Bolt is active — player may tap a creature or "Bolt Hero".
        case selectingLightningTarget (cardIndex: Int)
        /// Odysseus is resolving — player picks one of the top 2 deck cards.
        case odysseusChoice (top2: [Card], cardIndex: Int)
        /// Necromancy is resolving — player picks a creature from their discard.
        case necromancyChoice (creatures: [Card], cardIndex: Int)
    }

    // MARK: - Perspective Helpers

    /// The most recent game snapshot. Falls back to `initialSnapshot` if the
    /// manager has not yet received an update from Firebase.
    var snapshot: MPGameSnapshot { manager.gameSnapshot ?? initialSnapshot }

    /// The local player's data, resolved by role.
    /// The host always occupies `hostPlayer`; the guest occupies `guestPlayer`.
    var me:   MPPlayer { manager.localPlayer  ?? (manager.isHost ? snapshot.hostPlayer   : snapshot.guestPlayer) }

    /// The remote opponent's data, resolved as the opposite role to `me`.
    var them: MPPlayer { manager.remotePlayer ?? (manager.isHost ? snapshot.guestPlayer  : snapshot.hostPlayer) }

    // MARK: - Derived State

    /// Delegates turn authority to the manager, which tracks whose turn it is
    /// based on the `currentTurn` field in the snapshot and the client's role.
    var isMyTurn: Bool { manager.isMyTurn }

    /// `true` when `snapshot.gameResult` is anything other than `"ongoing"`.
    var gameOver: Bool { snapshot.gameResult != "ongoing" }

    /// `true` if the local player won the match, resolved by comparing their
    /// role (host/guest) against the snapshot's result string.
    var iWon: Bool {
        (manager.isHost  && snapshot.gameResult == "hostWon") ||
        (!manager.isHost && snapshot.gameResult == "guestWon")
    }

    /// `true` when the game ended because the opponent tapped Quit mid-match,
    /// used to display a context-appropriate game-over message.
    var isForfeit: Bool { snapshot.message == "Opponent forfeited." }

    // MARK: - Targeting Highlight Helpers

    /// `true` when the active targeting mode expects the player to tap an
    /// opponent creature, used to apply the red highlight to all enemy board tokens.
    var showTargetHighlight: Bool {
        switch targetingMode {
        case .selectingOpponentCreature, .selectingLightningTarget: return true
        default: return false
        }
    }

    /// `true` when the active targeting mode expects the player to tap one of
    /// their own creatures, used to apply the green highlight to all friendly tokens.
    var showFriendlyHighlight: Bool {
        if case .selectingFriendlyCreature = targetingMode { return true }
        return false
    }

    /// `true` specifically during Lightning Bolt targeting, used to show the
    /// "Bolt Hero" button in the control bar as an alternative to a creature target.
    var isLightningTargeting: Bool {
        if case .selectingLightningTarget = targetingMode { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color (hex: "0a0a0a").ignoresSafeArea ()

            // Five board regions stacked vertically, matching the layout of
            // `GameBoardView`. Implemented as computed properties rather than
            // dedicated structs so all targeting state remains in a single scope.
            VStack (spacing: 0) {
                opponentArea
                divider
                playerArea
                playerHand
                controlBar
            }

            // Game-over overlay rendered on top of the board when the match ends.
            if gameOver {
                gameOverOverlay
            }

            // Card-picker overlays for abilities that require choosing from a
            // list of cards. The selected card's ID is sent as part of the
            // MPGameAction so the server can resolve the correct card choice.
            switch targetingMode {
            case .odysseusChoice (let top2, _):
                CardPickerOverlay (
                    title: "Odysseus — Pick a Card",
                    subtitle: "One goes to your hand. The other is discarded.",
                    cards: top2,
                    onPick: { card in
                        if case .odysseusChoice (_, let ci) = targetingMode {
                            // Dispatch the choice as a network action, including the
                            // chosen card's ID so the server resolves the correct card.
                            manager.sendAction (MPGameAction (type: .resolveOdysseus, cardIndex: ci, chosenCardId: card.id))
                        }
                        targetingMode = .none
                    },
                    onCancel: { targetingMode = .none }
                )
            case .necromancyChoice (let creatures, _):
                CardPickerOverlay (
                    title: "Necromancy — Revive a Creature",
                    subtitle: "Pick a creature from your discard pile to bring back.",
                    cards: creatures,
                    onPick: { card in
                        if case .necromancyChoice (_, let ci) = targetingMode {
                            manager.sendAction (MPGameAction (type: .resolveNecromancy, cardIndex: ci, chosenCardId: card.id))
                        }
                        targetingMode = .none
                    },
                    onCancel: { targetingMode = .none }
                )
            default:
                EmptyView ()
            }
        }
        .navigationBarHidden (true)
        // Mirror `snapshot.message` into `localMessage` on every change and
        // regenerate `messageId` to reset the scroll position of the message bar.
        .onChange (of: snapshot.message) {
            if !snapshot.message.isEmpty {
                localMessage = snapshot.message
                messageId = UUID ()
            }
        }
    }

    // MARK: - Opponent Area

    /// Renders the opponent's stats (hand count, health, mana bar), their
    /// face-down hand representation, and their live board creatures.
    ///
    /// Opponent creatures show the red attack-target highlight when an attacker
    /// is selected OR when a targeting mode that expects an enemy creature is active,
    /// matching the behaviour in `OpponentAreaView` in the single-player board.
    var opponentArea: some View {
        VStack (spacing: 6) {

            // Stats bar: hand count (left), health (centre), mana + bar (right).
            HStack {
                // Face-down hand count — shows the opponent has cards without
                // revealing what they are.
                HStack (spacing: 4) {
                    Image (systemName: "rectangle.stack.fill")
                        .font (.system (size: 11))
                        .foregroundColor (.white.opacity (0.5))
                    Text ("\(them.hand.count)")
                        .font (.system (size: 12, weight: .semibold))
                        .foregroundColor (.white.opacity (0.6))
                }
                Spacer ()
                HStack (spacing: 6) {
                    Image (systemName: "heart.fill")
                        .foregroundColor (.red)
                        .font (.system (size: 14))
                    Text ("\(them.health)")
                        .font (.system (size: 20, weight: .black))
                        .foregroundColor (.white)
                }
                Spacer ()
                // Mana display with proportional fill bar. Division is guarded
                // against zero to prevent a crash at the very start of the match.
                HStack (spacing: 6) {
                    Image (systemName: "drop.fill")
                        .font (.system (size: 10))
                        .foregroundColor (Color (hex: "1a6fd4"))
                    Text ("\(them.mana)/\(them.maxMana)")
                        .font (.system (size: 12, weight: .bold))
                        .foregroundColor (Color (hex: "1a6fd4"))
                    GeometryReader { geo in
                        ZStack (alignment: .leading) {
                            RoundedRectangle (cornerRadius: 3)
                                .fill (Color.white.opacity (0.1))
                            RoundedRectangle (cornerRadius: 3)
                                .fill (Color (hex: "1a6fd4"))
                                .frame (width: them.maxMana > 0
                                    ? geo.size.width * CGFloat (them.mana) / CGFloat (them.maxMana)
                                    : 0)
                        }
                    }
                    .frame (width: 50, height: 7)
                }
            }
            .padding (.horizontal, 16)
            .padding (.top, 8)

            // Face-down hand: one card-back rectangle per card in the opponent's
            // hand. Negative spacing creates the fanned overlap effect.
            HStack (spacing: -8) {
                ForEach (0..<them.hand.count, id: \.self) { _ in
                    RoundedRectangle (cornerRadius: 4)
                        .fill (Color (hex: "1a1a2e"))
                        .frame (width: 28, height: 42)
                        .overlay (RoundedRectangle (cornerRadius: 4).stroke (Color.white.opacity (0.2), lineWidth: 1))
                }
            }
            .frame (height: 44)

            // Opponent board creatures. Tap handling is delegated to
            // `handleOpponentCreatureTap` which resolves the correct network
            // action based on the current targeting mode.
            ScrollView (.horizontal, showsIndicators: false) {
                HStack (spacing: 8) {
                    if them.board.isEmpty {
                        Text ("No creatures")
                            .font (.system (size: 12))
                            .foregroundColor (.white.opacity (0.2))
                            .frame (height: 80)
                    } else {
                        ForEach (them.board.indices, id: \.self) { i in
                            BoardCreatureView (
                                card: them.board [i],
                                isAttackTarget: attackerIndex != nil || showTargetHighlight,
                                isOpponent: true
                            ) {
                                handleOpponentCreatureTap (index: i)
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

    // MARK: - Battlefield Divider

    /// The horizontal strip between the two board halves, showing whose turn it
    /// is and scrolling the most recent game event message.
    ///
    /// Uses `localMessage` rather than `snapshot.message` directly so that the
    /// displayed text persists across rapid snapshot updates — the `.onChange`
    /// modifier on the body copies new messages in only when they are non-empty.
    /// `messageId` resets the scroll position on each new message using the same
    /// UUID identity trick as `BattlefieldDivider` in the single-player board.
    var divider: some View {
        ZStack {
            // Soft centred red gradient line — fades to clear at the edges.
            Rectangle ()
                .fill (LinearGradient (colors: [.clear, Color.red.opacity (0.4), .clear], startPoint: .leading, endPoint: .trailing))
                .frame (height: 1)

            HStack (spacing: 10) {
                // Turn indicator badge — green on your turn, red on theirs.
                Text (isMyTurn ? "YOUR TURN" : "OPPONENT'S TURN")
                    .font (.system (size: 10, weight: .black))
                    .foregroundColor (isMyTurn ? .green : .red.opacity (0.8))
                    .padding (.horizontal, 10)
                    .padding (.vertical, 4)
                    .background (
                        RoundedRectangle (cornerRadius: 4)
                            .fill (isMyTurn ? Color.green.opacity (0.15) : Color.red.opacity (0.1))
                            .overlay (RoundedRectangle (cornerRadius: 4).stroke (isMyTurn ? Color.green.opacity (0.5) : Color.red.opacity (0.3), lineWidth: 1))
                    )
                    .fixedSize ()

                // Scrolling game message — only rendered when there is content.
                if !localMessage.isEmpty {
                    ScrollView (.horizontal, showsIndicators: false) {
                        Text (localMessage)
                            .font (.system (size: 10))
                            .foregroundColor (.white.opacity (0.55))
                            .fixedSize ()
                            .id (messageId)   // Identity reset scrolls back to the leading edge on new messages.
                    }
                    .frame (maxWidth: .infinity)
                }
            }
            .padding (.horizontal, 12)
        }
        .frame (height: 30)
    }

    // MARK: - Player Area

    /// Renders the local player's board creatures and their stat bar
    /// (mana, health, hand count).
    ///
    /// Tap handling for friendly creatures is delegated to
    /// `handleFriendlyCreatureTap`, which either resolves a pending friendly-
    /// targeting spell (dispatching an `MPGameAction`) or toggles attacker selection.
    var playerArea: some View {
        VStack (spacing: 6) {
            ScrollView (.horizontal, showsIndicators: false) {
                HStack (spacing: 8) {
                    if me.board.isEmpty {
                        Text ("No creatures — play cards from your hand")
                            .font (.system (size: 12))
                            .foregroundColor (.white.opacity (0.2))
                            .frame (height: 80)
                    } else {
                        ForEach (me.board.indices, id: \.self) { i in
                            BoardCreatureView (
                                card: me.board [i],
                                // Highlight if this creature is the selected attacker
                                // OR if a friendly-targeting spell is waiting for input.
                                isSelected: attackerIndex == i || showFriendlyHighlight,
                                isAttackTarget: false,
                                isOpponent: false
                            ) {
                                handleFriendlyCreatureTap (index: i)
                            }
                        }
                    }
                }
                .padding (.horizontal, 12)
            }
            .frame (height: 90)

            // Stats bar: mana (left), health (centre), hand count (right).
            HStack {
                HStack (spacing: 6) {
                    Image (systemName: "drop.fill")
                        .font (.system (size: 12))
                        .foregroundColor (Color (hex: "1a6fd4"))
                    Text ("\(me.mana)/\(me.maxMana)")
                        .font (.system (size: 14, weight: .black))
                        .foregroundColor (Color (hex: "1a6fd4"))
                    GeometryReader { geo in
                        ZStack (alignment: .leading) {
                            RoundedRectangle (cornerRadius: 3)
                                .fill (Color.white.opacity (0.1))
                            RoundedRectangle (cornerRadius: 3)
                                .fill (Color (hex: "1a6fd4"))
                                .frame (width: me.maxMana > 0
                                    ? geo.size.width * CGFloat (me.mana) / CGFloat (me.maxMana)
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
                    Text ("\(me.health)")
                        .font (.system (size: 20, weight: .black))
                        .foregroundColor (.white)
                }
                Spacer ()
                HStack (spacing: 4) {
                    Image (systemName: "rectangle.stack.fill")
                        .font (.system (size: 11))
                        .foregroundColor (.white.opacity (0.5))
                    Text ("\(me.hand.count)")
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

    // MARK: - Player Hand

    /// A horizontally scrollable strip of the local player's current hand.
    ///
    /// Follows the same two-tap-to-play interaction model as `PlayerHandView`
    /// in the single-player board: first tap selects, second tap calls
    /// `attemptPlay(cardIndex:)` which either enters a targeting mode or
    /// dispatches a `.playCard` action immediately.
    ///
    /// Tapping any hand card while a targeting mode is active cancels the
    /// targeting instead of selecting a new card, preventing accidental plays
    /// while a spell awaits a target.
    var playerHand: some View {
        ScrollView (.horizontal, showsIndicators: false) {
            HStack (spacing: 8) {
                ForEach (me.hand.indices, id: \.self) { i in
                    let card = me.hand [i]
                    let isSelected = selectedCardIndex == i
                    let cost = me.effectiveManaCost (card)
                    let isPlayable = isMyTurn && me.mana >= cost

                    ZStack {
                        // White blur halo behind the selected card, mirroring
                        // the effect in `PlayerHandView`.
                        if isSelected {
                            RoundedRectangle (cornerRadius: 10)
                                .stroke (Color.white, lineWidth: 2.5)
                                .blur (radius: 4)
                                .opacity (0.6)
                        }
                        CardView (card: card, isSelected: isSelected, isPlayable: isPlayable)
                    }
                    .onTapGesture {
                        guard isMyTurn else { return }
                        // Cancel any active targeting rather than selecting a card.
                        if case .none = targetingMode {
                        } else {
                            targetingMode = .none
                            selectedCardIndex = nil
                            return
                        }
                        if isSelected {
                            attemptPlay (cardIndex: i)
                        } else {
                            selectedCardIndex = i
                            attackerIndex = nil
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

    // MARK: - Control Bar

    /// The bottom action bar with Quit, Attack Hero, Bolt Hero, a context hint,
    /// and End Turn — identical in layout to `ControlBarView` in the single-player
    /// board, but all actions dispatch `MPGameAction` values rather than calling
    /// `GameState` methods directly.
    ///
    /// The Quit button calls `manager.leaveGame()` before dismissing, which writes
    /// a forfeit result to Firebase so the opponent sees "Opponent forfeited." rather
    /// than a silent disconnection.
    var controlBar: some View {
        HStack (spacing: 10) {

            // Quit — notifies the server of the forfeit before popping the view.
            Button (action: {
                manager.leaveGame ()
                dismiss ()
            }) {
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

            // Attack Hero — only visible when an attacker is selected and the
            // opponent's board is empty, enforcing the direct-attack rule in the UI.
            if attackerIndex != nil && them.board.isEmpty {
                Button (action: {
                    if let ai = attackerIndex {
                        manager.sendAction (MPGameAction (type: .attackHero, attackerIndex: ai))
                        attackerIndex = nil
                    }
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

            // Bolt Hero — only visible during Lightning Bolt targeting, providing
            // the alternative to selecting a creature target.
            if isLightningTargeting {
                Button (action: {
                    if case .selectingLightningTarget (let ci) = targetingMode {
                        manager.sendAction (MPGameAction (type: .selectLightningHero, cardIndex: ci))
                    }
                    targetingMode = .none
                    selectedCardIndex = nil
                }) {
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

            // Context hint — one-line instruction that updates with targeting state.
            contextHint

            Spacer ()

            // End Turn — dispatches a `.endTurn` action to Firebase and clears
            // all local selection state. Relabelled and disabled when it is not
            // the local player's turn.
            Button (action: {
                guard isMyTurn else { return }
                manager.sendAction (MPGameAction (type: .endTurn))
                selectedCardIndex = nil
                attackerIndex = nil
                targetingMode = .none
            }) {
                HStack (spacing: 5) {
                    Text (isMyTurn ? "End Turn" : "Waiting...")
                        .font (.system (size: 14, weight: .bold))
                    if isMyTurn {
                        Image (systemName: "arrow.right.circle.fill").font (.system (size: 14))
                    }
                }
                .foregroundColor (isMyTurn ? .white : .white.opacity (0.3))
                .padding (.horizontal, 14)
                .padding (.vertical, 10)
                .background (isMyTurn ? Color.red.opacity (0.3) : Color.white.opacity (0.05))
                .cornerRadius (8)
                .overlay (RoundedRectangle (cornerRadius: 8).stroke (isMyTurn ? Color.red : Color.white.opacity (0.1), lineWidth: 1.5))
            }
            .disabled (!isMyTurn)
        }
        .padding (.horizontal, 12)
        .padding (.vertical, 10)
        .background (Color (hex: "0d0d0d"))
    }

    // MARK: - Context Hint

    /// A `@ViewBuilder` computed property that renders a short one-line instruction
    /// in the centre of the control bar, updating automatically as `targetingMode`
    /// and selection state change. Matches the contextHint in `ControlBarView`
    /// in structure and content.
    @ViewBuilder var contextHint: some View {
        switch targetingMode {
        case .none:
            if selectedCardIndex != nil {
                Text ("Tap again to play").font (.system (size: 11)).foregroundColor (.white.opacity (0.5))
            } else if attackerIndex != nil {
                Text (them.board.isEmpty ? "Tap Attack Hero" : "Tap a target")
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

    // MARK: - Game Over Overlay

    /// Full-screen modal shown when `gameOver` is `true`.
    ///
    /// Unlike the single-player game-over screen, there is no "Play Again" option
    /// here — both players must return to the main menu and go through matchmaking
    /// again to start a new online match. The "Main Menu" button calls
    /// `manager.leaveGame()` to cleanly close the Firebase connection before dismissing.
    ///
    /// Four distinct outcome messages handle all combinations of win/loss and
    /// forfeit, using a chained ternary for conciseness.
    var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity (0.75).ignoresSafeArea ()
            VStack (spacing: 24) {

                // Result headline — gold for victory, red for defeat.
                Text (iWon ? "VICTORY" : "DEFEAT")
                    .font (.system (size: 56, weight: .heavy))
                    .foregroundColor (iWon ? Color (hex: "FFD700") : .red)
                    .shadow (color: iWon ? Color (hex: "FFD700").opacity (0.6) : Color.red.opacity (0.6), radius: 20)

                // Context-aware flavour text covering all four outcome scenarios:
                // won by forfeit, lost by forfeit, won in play, lost in play.
                Text (isForfeit && iWon
                    ? "Your opponent forfeited. Victory by default."
                    : isForfeit && !iWon
                    ? "You forfeited the match."
                    : iWon
                    ? "The gods smile upon you."
                    : "You have fallen in battle."
                )
                .font (.system (size: 16))
                .foregroundColor (.white.opacity (0.7))
                .multilineTextAlignment (.center)

                // Main Menu — cleans up the Firebase session before navigating away.
                Button ("Main Menu") {
                    manager.leaveGame ()
                    dismiss ()
                }
                .font (.system (size: 15, weight: .bold))
                .foregroundColor (.white)
                .padding (.horizontal, 24).padding (.vertical, 12)
                .background (Color.red.opacity (0.3)).cornerRadius (10)
                .overlay (RoundedRectangle (cornerRadius: 10).stroke (Color.red, lineWidth: 1.5))
            }
            .padding (40)
            .background (
                RoundedRectangle (cornerRadius: 20).fill (Color (hex: "111111"))
                    .overlay (RoundedRectangle (cornerRadius: 20).stroke (Color.red.opacity (0.3), lineWidth: 1.5))
            )
            .padding (32)
        }
    }

    // MARK: - Action Dispatch

    /// Determines whether a card play requires a targeting step before it can
    /// be dispatched, and either enters the appropriate `MPTargetingMode` or
    /// sends a `.playCard` action immediately.
    ///
    /// This is the multiplayer equivalent of `playCardFromHand(at:)` in `GameState`,
    /// but with one key difference: spells and creature abilities that need targets
    /// set a local `targetingMode` rather than mutating game state. The actual
    /// action is only dispatched once the player completes their selection, keeping
    /// the Firebase snapshot clean of half-resolved states.
    func attemptPlay (cardIndex: Int) {
        let card = me.hand [cardIndex]

        if card.type == .spell {
            switch card.name {
            case "Prometheus's Fire":
                guard !me.board.isEmpty else { return }
                targetingMode = .selectingFriendlyCreature (spell: card.name, cardIndex: cardIndex)
            case "Shield of Sparta":
                guard !me.board.isEmpty else { return }
                targetingMode = .selectingFriendlyCreature (spell: card.name, cardIndex: cardIndex)
            case "Sisyphus's Burden":
                guard !them.board.isEmpty else { return }
                targetingMode = .selectingOpponentCreature (spell: card.name, cardIndex: cardIndex)
            case "Curse of Circe":
                guard !them.board.isEmpty else { return }
                targetingMode = .selectingOpponentCreature (spell: card.name, cardIndex: cardIndex)
            case "Lightning Bolt":
                targetingMode = .selectingLightningTarget (cardIndex: cardIndex)
            case "Necromancy":
                // Filter and reset discard creatures locally to populate the
                // picker overlay, then wait for the player's choice before dispatching.
                let creatures = me.discard.filter { $0.type != .spell }
                guard !creatures.isEmpty else { return }
                let revivable = creatures.map { c -> Card in var n = c; n.currentHealth = n.health; n.currentAttack = n.attack; return n }
                targetingMode = .necromancyChoice (creatures: revivable, cardIndex: cardIndex)
            default:
                // No targeting needed — dispatch immediately.
                manager.sendAction (MPGameAction (type: .playCard, cardIndex: cardIndex))
                selectedCardIndex = nil
            }
        } else {
            switch card.name {
            case "Odysseus":
                // Peek at the top 2 cards locally to populate the picker overlay.
                // The actual deck mutation happens server-side when the choice is dispatched.
                guard me.deck.count >= 1 else { break }
                let top2 = Array (me.deck.prefix (2))
                targetingMode = .odysseusChoice (top2: top2, cardIndex: cardIndex)
                return
            case "Heracles":
                // Only enter targeting mode if there are valid targets (health ≤ 2).
                // If not, fall through to play Heracles as a plain creature.
                let validTargets = them.board.filter { ($0.currentHealth ?? 0) <= 2 }
                if !validTargets.isEmpty {
                    targetingMode = .selectingOpponentCreature (spell: "Heracles", cardIndex: cardIndex)
                    return
                }
            default: break
            }
            // No targeting required — dispatch the creature play immediately.
            manager.sendAction (MPGameAction (type: .playCard, cardIndex: cardIndex))
            selectedCardIndex = nil
        }
    }

    // MARK: - Tap Handlers

    /// Handles a tap on one of the local player's board creatures.
    ///
    /// If a friendly-targeting spell is active, dispatches the target selection
    /// as a network action and clears targeting state. Otherwise, toggles attacker
    /// selection: tapping the already-selected creature deselects it; tapping a
    /// different ready creature selects it as the new attacker.
    func handleFriendlyCreatureTap (index: Int) {
        if case .selectingFriendlyCreature (_, let ci) = targetingMode {
            // Resolve the pending spell by sending the chosen creature's board index.
            manager.sendAction (MPGameAction (type: .selectFriendlyTarget, cardIndex: ci, targetBoardIndex: index))
            targetingMode = .none
            selectedCardIndex = nil
            return
        }
        // Not in a targeting mode — handle as attacker selection.
        guard isMyTurn, me.board [index].canAttack else { return }
        attackerIndex = attackerIndex == index ? nil : index   // Toggle deselection.
        selectedCardIndex = nil
        targetingMode = .none
    }

    /// Handles a tap on one of the opponent's board creatures.
    ///
    /// The correct network action is resolved based on the active targeting mode:
    /// - Spell targeting → dispatch `selectOpponentTarget`
    /// - Lightning Bolt targeting → dispatch `selectLightningCreature`
    /// - Normal combat → dispatch `attackCreature` if an attacker is selected
    ///
    /// Minotaur taunt is enforced locally (showing a message) before the attack
    /// action is dispatched, preventing the invalid action from reaching Firebase.
    func handleOpponentCreatureTap (index: Int) {
        switch targetingMode {
        case .selectingOpponentCreature (_, let ci):
            manager.sendAction (MPGameAction (type: .selectOpponentTarget, cardIndex: ci, targetBoardIndex: index))
            targetingMode = .none
            selectedCardIndex = nil

        case .selectingLightningTarget (let ci):
            manager.sendAction (MPGameAction (type: .selectLightningCreature, cardIndex: ci, targetBoardIndex: index))
            targetingMode = .none
            selectedCardIndex = nil

        default:
            if let ai = attackerIndex {
                // Enforce Minotaur taunt client-side before dispatching the attack.
                if them.board.contains (where: { $0.name == "Minotaur" }) && them.board [index].name != "Minotaur" {
                    localMessage = "The Minotaur must be attacked first!"
                    messageId = UUID ()
                    return
                }
                manager.sendAction (MPGameAction (type: .attackCreature, attackerIndex: ai, defenderIndex: index))
                attackerIndex = nil
            }
        }
    }
}
