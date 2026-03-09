import Foundation
import Combine

// MARK: - Player
/// Represents a single player's in-game state: their resources, zones, and
/// the actions they can perform on those zones.
///
/// Modelled as a `struct` rather than a `class` so that mutations to player
/// state (drawing a card, spending mana, taking damage) produce value-semantic
/// copies. `GameState` holds `@Published` `Player` properties, so any mutation
/// automatically triggers a SwiftUI view update via the `ObservableObject` pipeline.
struct Player {

    // MARK: Resources

    /// Current hero health. Both players start at 30. The game ends when this
    /// reaches 0 or below.
    var health: Int = 30

    /// Mana available to spend this turn. Refreshed to `maxMana` at the start
    /// of each of the player's turns and decremented by `spendMana(_:)` as cards
    /// are played.
    var mana: Int = 0

    /// The mana cap for this turn, equal to the current turn number (max 10).
    /// Stored separately from `mana` so the UI can display the "X/Y" format and
    /// render the proportional mana bar without additional computation.
    var maxMana: Int = 0

    // MARK: Card Zones

    /// Cards currently in the player's hand, available to play.
    var hand: [Card] = []

    /// The draw pile. Cards are taken from the front with `removeFirst()`.
    var deck: [Card] = []

    /// Creatures and spells currently on the battlefield.
    var board: [Card] = []

    /// Cards that have been played (spells) or killed (creatures). When the
    /// deck runs out, the discard pile is reshuffled into a new deck with stats
    /// reset, preventing the game from stalling on an empty draw pile.
    var discard: [Card] = []

    /// `true` for human-controlled players, `false` for AI opponents.
    /// Used in `GameState` to decide whether to run the AI turn loop.
    var isHuman: Bool = true

    // MARK: Mutating Methods

    /// Draws one card from the top of the deck into the hand.
    ///
    /// If the deck is empty but the discard pile is not, the discard pile is
    /// shuffled and recycled into a fresh deck first. Cards drawn from a recycled
    /// deck have their `currentHealth` and `currentAttack` reset to base values
    /// and `canAttack` cleared, as if they were brand-new copies. This prevents
    /// a "free heal" exploit where a previously damaged creature re-enters with
    /// its reduced stats.
    mutating func drawCard () {
        if deck.isEmpty && !discard.isEmpty {
            deck = discard.shuffled ().map { card in
                var c = card
                c.currentHealth = c.health
                c.currentAttack = c.attack
                c.canAttack = false
                return c
            }
            discard = []
        }
        guard !deck.isEmpty else { return }
        let card = deck.removeFirst ()
        hand.append (card)
    }

    /// Refreshes mana at the start of the player's turn.
    ///
    /// `maxMana` is set to `min(turn, 10)` — one additional mana per turn,
    /// capped at 10. Both `mana` and `maxMana` are updated together so the
    /// mana bar in `PlayerAreaView` is always accurate.
    mutating func gainMana (turn: Int) {
        maxMana = min (turn, 10)
        mana = maxMana
    }

    /// Deducts `amount` from available mana, floored at 0 to prevent negative
    /// mana values that could otherwise be exploited by playing free cards.
    mutating func spendMana (_ amount: Int) {
        mana = max (0, mana - amount)
    }

    /// Returns the mana cost the player would pay to play `card`, accounting
    /// for the Medea passive ability ("Spells cost 1 less mana").
    ///
    /// Checking the board for Medea here keeps cost calculation centralised so
    /// both the playability check in `PlayerHandView` and the deduction in
    /// `commitPlay` use the same value, eliminating any risk of mismatch.
    func effectiveManaCost (_ card: Card) -> Int {
        if card.type == .spell && board.contains (where: { $0.name == "Medea" }) {
            return max (0, card.manaCost - 1)   // Floor at 0 — spells can never cost negative mana.
        }
        return card.manaCost
    }

    /// Returns `true` if Ares is currently on this player's board.
    ///
    /// Used throughout `GameState` to determine whether newly played or summoned
    /// creatures should receive the Ares passive "+1 attack to all your creatures"
    /// bonus at the moment they enter the battlefield.
    func hasAres () -> Bool {
        return board.contains { $0.name == "Ares" }
    }
}

// MARK: - Supporting Enumerations

/// Represents the four phases of a turn. Currently used to gate certain
/// actions (e.g. drawing only during `.draw`, playing cards during `.main`).
enum GamePhase { case draw, main, attack, end }

/// Selects the game mode passed into `GameState` at initialisation.
enum GameMode { case vsHuman, vsAI }

/// Tracks the outcome of the match. `GameBoardView` observes this to decide
/// whether to render `GameOverOverlay`.
enum GameResult { case playerWon, opponentWon, ongoing }

// MARK: - TargetingMode
/// Describes the interaction state when a card ability requires the player to
/// make a follow-up choice before the effect resolves.
///
/// Storing the originating `cardIndex` in each case allows the resolution
/// functions to safely remove the card from hand and charge its mana cost
/// even after the player has navigated away from their initial selection.
///
/// Cases that carry `[Card]` payloads (Odysseus, Necromancy) pass the relevant
/// card subset directly so the `CardPickerOverlay` can render them without
/// querying game state independently, keeping the overlay purely presentational.
enum TargetingMode {
    /// No pending targeting decision — the normal idle state.
    case none

    /// A spell that targets a single opponent creature is waiting for the
    /// player to tap one (e.g. Curse of Circe, Sisyphus's Burden).
    case selectingOpponentCreature(spell: String, cardIndex: Int)

    /// A spell that targets a friendly creature is waiting for the player
    /// to tap one (e.g. Prometheus's Fire, Shield of Sparta).
    case selectingFriendlyCreature(spell: String, cardIndex: Int)

    /// Lightning Bolt is waiting — the player may tap a creature OR the
    /// "Bolt Hero" button to target the opponent directly.
    case selectingLightningTarget(cardIndex: Int)

    /// Odysseus has been triggered. The player must choose one of `top2` cards
    /// to keep; the other is discarded.
    case odysseusChoice(top2: [Card], cardIndex: Int)

    /// Necromancy has been triggered. The player must choose one creature from
    /// `creatures` (their discard pile) to revive onto the board.
    case necromancyChoice(creatures: [Card], cardIndex: Int)
}

// MARK: - GameState
/// The authoritative game engine for a single OLYMPUS match.
///
/// `GameState` owns all mutable match data and exposes it as `@Published`
/// properties so that `GameBoardView` and its sub-views re-render automatically
/// whenever game state changes. It is instantiated as a `@StateObject` in
/// `GameBoardView`, ensuring exactly one instance lives for the duration of
/// the match.
///
/// Responsibilities:
/// - Turn lifecycle (`startTurn`, `endTurn`)
/// - Card play and spell resolution (`playCardFromHand`, `commitPlay`, `resolveSpell`)
/// - Combat resolution (`attackCreature`, `attackHero`, `leonidasProtects`)
/// - Targeting state machine (`selectFriendlyTarget`, `selectOpponentTarget`,
///   `selectLightningTarget`, `resolveOdysseusChoice`, `resolveNecromancyChoice`)
/// - Death checking and triggered death effects (`removeDeadPlayerCreatures`,
///   `removeDeadOpponentCreatures`, `spawnHydraHeads`)
/// - Win condition evaluation (`checkWinCondition`)
/// - AI opponent logic (`runAITurnWithDelay`, `aiPlayOptimalCards`,
///   `aiCardPriority`, `aiExecuteNextAttack`, `aiChooseBestAttacker`,
///   `aiChooseBestTarget`, `aiCanGoLethal`)
/// - Game logging (`log(_:)`)
class GameState: ObservableObject {

    // MARK: Published State
    // Every property below triggers a view update when mutated, keeping the
    // UI in sync with the game engine without manual refresh calls.

    /// The human player's full state (hand, board, deck, mana, health).
    @Published var player: Player

    /// The opposing player's state — AI-controlled when `mode == .vsAI`.
    @Published var opponent: Player

    /// Monotonically increasing turn counter. Incremented when the turn
    /// flips back to the player, so each full round (player + opponent) = +1.
    @Published var currentTurn: Int = 1

    /// `true` during the player's turn, `false` during the opponent's.
    /// Gates all player-initiated actions and drives the AI turn trigger.
    @Published var isPlayerTurn: Bool = true

    /// The current phase of the active turn. Used to enforce action ordering.
    @Published var phase: GamePhase = .draw

    /// The match outcome. Observed by `GameBoardView` to show `GameOverOverlay`.
    @Published var gameResult: GameResult = .ongoing

    /// The index of the card currently selected in the player's hand, or `nil`
    /// if no card is selected. Drives the highlight state in `PlayerHandView`.
    @Published var selectedCardIndex: Int? = nil

    /// The board index of the creature the player has chosen as their attacker,
    /// or `nil` if no attacker is selected. Drives the green highlight in
    /// `PlayerAreaView` and reveals the "Attack Hero" button in `ControlBarView`.
    @Published var attackerIndex: Int? = nil

    /// The most recent game event string, displayed in `BattlefieldDivider`.
    /// Also appended to `gameLog` for a full session history.
    @Published var message: String = ""

    /// Queue of pending log messages waiting to be displayed.
    /// Messages are drained one at a time with a minimum on-screen duration
    /// so the player always has time to read each one.
    private var messageQueue: [String] = []

    /// True while a message is being held on screen for its minimum duration.
    /// Guards against the drain loop consuming entries faster than they can be read.
    private var isDisplayingMessage = false

    /// Minimum time (seconds) each message stays on screen before the next replaces it.
    private let messageDisplayDuration: TimeInterval = 1.0

    /// A rolling history of the last 30 game events. Capped to prevent
    /// unbounded memory growth in long matches.
    @Published var gameLog: [String] = []

    /// The current targeting state. When not `.none`, the UI switches into a
    /// targeting interaction mode appropriate for the active case, and most
    /// normal player actions are suppressed until a target is chosen or the
    /// mode is cancelled.
    @Published var targetingMode: TargetingMode = .none

    // MARK: Non-Published State

    /// The game mode selected at launch. Not published because it never
    /// changes during a match — it only needs to be read, not observed.
    var mode: GameMode

    /// IDs of creatures currently under Sisyphus's Burden. A creature in this
    /// set skips its next `canAttack = true` reset at the end of the **opponent's**
    /// turn (i.e. the turn after the spell is cast), then is removed from the set
    /// so normal attack eligibility resumes thereafter. Keyed by card `id` so
    /// token copies of the same card template are tracked independently.
    var burdenedCreatureIDs: Set<String> = []
    
    /// IDs of creatures currently under Prometheus's Fire. A creature in this
    /// set loses its `+2` attack bonus at the end of the **players's**
    /// turn (i.e. the turn after the spell is cast), then is removed from the set
    /// so normal attack power resumes thereafter. Keyed by card `id` so
    /// token copies of the same card template are tracked independently.
    var fireCreatureIDs: Set<String> = []

    /// IDs of creatures that currently have Athena's Divine Shield active.
    /// A creature is added here when it enters the board as Athena (or is revived).
    /// When it absorbs a hit, its ID is removed — the shield is permanently gone.
    /// Health values are NEVER modified for shield purposes; this set is the
    /// single source of truth for whether the shield is active.
    var shieldedCreatureIDs: Set<String> = []

    // MARK: Initialiser

    /// Creates a new `GameState`, initialises both players, and calls
    /// `setupGame()` to shuffle the deck and deal opening hands.
    init (mode: GameMode = .vsHuman) {
        self.mode = mode
        self.player   = Player (isHuman: true)
        self.opponent = Player (isHuman: mode == .vsHuman)
        setupGame ()
    }

    // MARK: - Game Setup

    /// Shuffles `Card.allCards` into independent decks for both players,
    /// deals four opening cards to each, and starts the first turn.
    ///
    /// Each player draws from their own independently shuffled copy of the
    /// shared card pool, so both players can hold the same card simultaneously.
    /// `prefix(30)` future-proofs the call — if `allCards` ever grows beyond
    /// 30 entries, the deck size remains capped without a separate constant.
    func setupGame () {
        player.deck   = Array (Card.allCards.shuffled ().prefix (30))
        opponent.deck = Array (Card.allCards.shuffled ().prefix (30))
        for _ in 0..<4 {
            player.drawCard ()
            opponent.drawCard ()
        }
        startTurn ()
    }

    // MARK: - Turn Lifecycle

    /// Executes the start-of-turn sequence for whichever player's turn it is:
    /// grants mana, draws a card, and resolves any "start of your turn" passive
    /// abilities (currently Apollo's per-turn healing).
    ///
    /// Apollo's heal is applied here rather than at the end of the previous turn
    /// so that the healed health is visible to the active player from the very
    /// beginning of their turn.
    func startTurn () {
        phase = .draw
        if isPlayerTurn {
            player.gainMana (turn: currentTurn)
            player.drawCard ()
            log ("\(currentTurn == 1 ? "Game starts!" : "Your turn begins.") You have \(player.mana) mana.")
            // Apollo passive: heal the active player for 2 at the start of their turn.
            if player.board.contains (where: { $0.name == "Apollo" }) {
                player.health += 2
                log ("Apollo heals you for 2! Health: \(player.health)")
            }
        } else {
            opponent.gainMana (turn: currentTurn)
            opponent.drawCard ()
            // Apollo passive applies silently for the AI — no message, matching
            // the convention that AI "internal" actions aren't narrated turn-by-turn.
            if opponent.board.contains (where: { $0.name == "Apollo" }) {
                opponent.health += 2
            }
            log ("Opponent's turn begins.")
        }
        phase = .main
    }

    /// Ends the current player's turn, cleans up transient UI state, refreshes
    /// creature attack flags, flips the active player, and starts the next turn.
    ///
    /// Health is fully restored to `card.health` at turn end rather than being
    /// tracked cumulatively. This is an intentional design simplification: damage
    /// dealt to creatures during a turn does not carry over to the next turn,
    /// keeping combat readable without requiring a separate "damage wears off" step.
    ///
    /// After flipping to the AI turn, `runAITurnWithDelay()` is called to schedule
    /// the AI's actions on the main queue with perceptible timing delays, creating
    /// the illusion of an opponent "thinking" without blocking the UI.
    func endTurn () {
        // Clear all transient selection state so nothing carries over.
        selectedCardIndex = nil
        attackerIndex = nil
        targetingMode = .none
        phase = .end

        // Reset all creatures' attack eligibility and restore health.
        // `canAttack = true` is set here (not at turn start) so that newly
        // played creatures gain attack eligibility on the *opponent's next turn*,
        // correctly implementing summoning sickness.
        //
        // Sisyphus's Burden: creatures whose IDs are in `burdenedCreatureIDs` skip
        // their `canAttack = true` reset this cycle (keeping them unable to attack
        // for the upcoming turn). Their ID is then removed from the set so they
        // recover normally on the following turn.
        //
        // Prometheus's Fire: creatures whose IDs are in `fireCreatureIDs` lose
        // their `+2` attack bonus (taking away the effect of the spell at
        // the end of their turn). Their ID is then removed from the set so they
        // have their normal attack power on the following turn.
        for i in player.board.indices {
            let id = player.board [i].id
            if burdenedCreatureIDs.contains (id) {
                player.board [i].canAttack = false
                burdenedCreatureIDs.remove (id)
            } else {
                player.board [i].canAttack = true
            }
            if fireCreatureIDs.contains (id) {
                player.board [i].currentAttack? -= 2
                fireCreatureIDs.remove (id)
            }
            player.board [i].currentHealth = player.board [i].health ?? 0
        }
        for i in opponent.board.indices {
            let id = opponent.board [i].id
            if burdenedCreatureIDs.contains (id) {
                opponent.board [i].canAttack = false
                burdenedCreatureIDs.remove (id)
            } else {
                opponent.board [i].canAttack = true
            }
            if fireCreatureIDs.contains (id) {
                opponent.board [i].currentAttack? -= 2
                fireCreatureIDs.remove (id)
            }
            opponent.board [i].currentHealth = opponent.board [i].health ?? 0
        }

        isPlayerTurn.toggle ()
        // Turn number increments only when control returns to the player,
        // ensuring each full round (player + opponent) counts as one turn.
        if isPlayerTurn { currentTurn += 1 }

        startTurn ()

        // Schedule the AI's turn sequence if this is a VS AI game and it is
        // now the opponent's turn.
        if mode == .vsAI && !isPlayerTurn {
            runAITurnWithDelay ()
        }
    }

    /// Resets the targeting state and clears the selected card index.
    /// Called when the player taps a hand card while a targeting mode is active,
    /// or explicitly cancels a card-picker overlay.
    func cancelTargeting () {
        targetingMode = .none
        selectedCardIndex = nil
    }

    // MARK: - Card Play

    /// Handles the player tapping a card in hand for the second time (the first
    /// tap selects it; the second tap plays it).
    ///
    /// For spells and creature abilities that require a follow-up targeting
    /// decision, this function sets the appropriate `targetingMode` and returns
    /// early — the actual card removal and mana deduction are deferred until the
    /// player completes their targeting choice in the relevant resolution function.
    ///
    /// For cards that can resolve immediately, `commitPlay(index:cost:)` is called
    /// directly to finalise the play.
    func playCardFromHand (at index: Int) {
        guard isPlayerTurn else { return }
        guard index < player.hand.count else { return }

        let card = player.hand [index]
        let cost = player.effectiveManaCost (card)
        guard player.mana >= cost else {
            log ("Not enough mana to play \(card.name).")
            return
        }

        // MARK: Spell Targeting Dispatch
        // Spells that need a target enter a targeting mode and return early.
        // The card stays in hand and mana is not yet deducted — both happen
        // inside the corresponding `select*` or `resolve*` function.
        if card.type == .spell {
            switch card.name {
            case "Prometheus's Fire":
                guard !player.board.isEmpty else { log ("No creatures to buff."); return }
                targetingMode = .selectingFriendlyCreature (spell: card.name, cardIndex: index)
                log ("Pick a creature to give +2 attack.")
                return

            case "Shield of Sparta":
                guard !player.board.isEmpty else { log ("No creatures to shield."); return }
                targetingMode = .selectingFriendlyCreature (spell: card.name, cardIndex: index)
                log ("Pick a creature to give +3 health.")
                return

            case "Sisyphus's Burden":
                guard !opponent.board.isEmpty else { log ("No enemy creatures."); return }
                if opponent.board.contains (where: { $0.name == "Poseidon" }) {
                    log ("Poseidon protects all enemy creatures — Sisyphus's Burden fizzles!")
                    return
                }
                targetingMode = .selectingOpponentCreature (spell: card.name, cardIndex: index)
                log ("Pick an enemy creature to prevent from attacking.")
                return

            case "Curse of Circe":
                guard !opponent.board.isEmpty else { log ("No enemy creatures."); return }
                if opponent.board.contains (where: { $0.name == "Poseidon" }) {
                    log ("Poseidon protects all enemy creatures — Curse of Circe fizzles!")
                    return
                }
                targetingMode = .selectingOpponentCreature (spell: card.name, cardIndex: index)
                log ("Pick an enemy creature to transform into a pig.")
                return

            case "Lightning Bolt":
                // Lightning Bolt can target a creature OR the hero directly, so
                // it uses its own dedicated targeting mode.
                targetingMode = .selectingLightningTarget (cardIndex: index)
                log ("Pick a target — enemy creature or tap 'Bolt Hero'.")
                return

            case "Necromancy":
                // Filter discard for creatures only (spells cannot be revived),
                // then reset their stats to base values before presenting the picker
                // so the player sees accurate information for what they'd be reviving.
                let rawCreatures = player.discard.filter { $0.type != .spell }
                guard !rawCreatures.isEmpty else { log ("No creatures in discard."); return }
                let creatures = rawCreatures.map { c -> Card in
                    var n = c; n.currentHealth = n.health; n.currentAttack = n.attack; return n
                }
                targetingMode = .necromancyChoice (creatures: creatures, cardIndex: index)
                log ("Pick a creature to revive.")
                return

            default:
                break
            }

        // MARK: Creature Ability Targeting Dispatch
        // Some creatures have on-play abilities that also need a targeting step.
        } else {
            switch card.name {
            case "Odysseus":
                guard player.deck.count >= 1 else { break }
                // Take the top 2 cards (or fewer if the deck is nearly empty)
                // and present them in the picker overlay without removing them
                // from the deck yet — removal happens in `resolveOdysseusChoice`.
                let top2 = Array (player.deck.prefix (2))
                targetingMode = .odysseusChoice (top2: top2, cardIndex: index)
                log ("Pick a card to add to your hand.")
                return

            case "Heracles":
                // Heracles can only use his destroy ability if Poseidon isn't protecting
                // the opponent's board. If blocked, he still enters as a plain 4/4.
                if !opponent.board.contains (where: { $0.name == "Poseidon" }) {
                    let validTargets = opponent.board.filter { ($0.currentHealth ?? 0) <= 2 }
                    if !validTargets.isEmpty {
                        targetingMode = .selectingOpponentCreature (spell: "Heracles", cardIndex: index)
                        log ("Pick an enemy creature with 2 or less health to destroy.")
                        return
                    }
                } else if opponent.board.contains (where: { ($0.currentHealth ?? 0) <= 2 }) {
                    log ("Poseidon protects enemy creatures — Heracles enters as a plain 4/4.")
                }

            default:
                break
            }
        }

        // No targeting required — resolve the play immediately.
        commitPlay (index: index, cost: cost)
    }

    /// Finalises a card play: deducts mana, removes the card from hand, places
    /// creatures onto the board (or resolves spells immediately), and fires any
    /// on-play triggered effects.
    ///
    /// This is the single point through which all committed plays flow, whether
    /// they arrived directly from `playCardFromHand` or after a targeting decision
    /// was resolved. Centralising the deduction here ensures mana is never double-
    /// charged or missed regardless of the path taken.
    func commitPlay (index: Int, cost: Int) {
        guard index < player.hand.count else { return }
        let card = player.hand [index]
        player.spendMana (cost)
        player.hand.remove (at: index)
        selectedCardIndex = nil
        targetingMode = .none

        if card.type == .spell {
            resolveSpell (card, for: &player, against: &opponent)
        } else {
            var played = card
            // Perseus has Charge (Rush) — he can attack on the turn he's played.
            // All other creatures enter with `canAttack = false` (summoning sickness).
            played.canAttack = (card.name == "Perseus")
            // If Ares is on the board, newly played creatures inherit his +1 attack
            // passive immediately upon entering the battlefield.
            if player.hasAres () && card.name != "Ares" {
                played.currentAttack = (played.currentAttack ?? 0) + 1
            }
            if card.name == "Athena" { shieldedCreatureIDs.insert (played.id) }
            player.board.append (played)
            log ("You played \(card.name).")
            resolvePlayerPlayEffect (card)
        }
        checkWinCondition ()
    }

    // MARK: - On-Play Effects (Player)

    /// Resolves triggered effects for player-controlled cards that fire when
    /// they enter the battlefield.
    ///
    /// Only cards with immediate on-play board effects are handled here. Cards
    /// whose abilities are passive (Poseidon, Medusa, Hades) or combat-triggered
    /// (Achilles, Leonidas) are handled at the point of use in the combat and
    /// death-check functions.
    func resolvePlayerPlayEffect (_ card: Card) {
        switch card.name {
        case "Zeus":
            // Zeus is a CREATURE ability — Poseidon only blocks spells.
            // Zeus AoE always hits regardless of whether Poseidon is in play.
            // Athena's Divine Shield absorbs the hit: shield breaks, zero damage to Athena.
            for i in opponent.board.indices {
                let dmg = opponent.board [i].name == "Achilles" ? 4 : 2
                if opponent.board [i].name == "Athena" && shieldedCreatureIDs.contains (opponent.board [i].id) {
                    shieldedCreatureIDs.remove (opponent.board [i].id)
                    log ("Zeus's lightning strikes Athena's Divine Shield!")
                } else {
                    opponent.board [i].currentHealth = (opponent.board [i].currentHealth ?? 0) - dmg
                }
            }
            removeDeadOpponentCreatures ()
            log ("Zeus strikes all enemies for 2!")

        case "Ares":
            // Ares immediately buffs all existing friendly creatures +1 attack.
            // The newly placed Ares itself is excluded — he already has his own stats.
            for i in player.board.indices where player.board [i].name != "Ares" {
                player.board [i].currentAttack = (player.board [i].currentAttack ?? 0) + 1
            }
            log ("Ares boosts all your creatures +1 attack!")

        case "Cerberus":
            // Cerberus replaces itself with three 2/2 tokens. The single Cerberus
            // card appended in `commitPlay` is removed and three head tokens are
            // inserted in its place. Each head respects the Ares passive.
            let idx = player.board.count - 1
            player.board.remove (at: idx)
            for _ in 0..<3 {
                var head = Card (name: "Cerberus", type: .monster, manaCost: 4, imageName: "cerberus", description: "Summons 3 separate 2/2 creatures instead of one.", attack: 2, health: 2)
                head.canAttack = false
                if player.hasAres () { head.currentAttack = (head.currentAttack ?? 0) + 1 }
                player.board.append (head)
            }
            log ("Cerberus splits into 3 heads!")

        default:
            break
        }
    }

    // MARK: - Targeting Resolution (Player)

    /// Resolves a spell that requires a friendly creature target.
    ///
    /// Called when the player taps one of their own board creatures while
    /// `targetingMode` is `.selectingFriendlyCreature`. Charges the mana cost,
    /// removes the spell from hand, applies the buff to the chosen creature,
    /// and moves the spell to the discard pile.
    ///
    /// Shield of Sparta increases both `currentHealth` and the base `health`
    /// value so the buff persists across turn-end health resets (which restore
    /// creatures to their `health` baseline). Prometheus's Fire only raises
    /// `currentAttack` because it is a temporary effect lasting until end of turn.
    func selectFriendlyTarget (boardIndex: Int) {
        guard case .selectingFriendlyCreature (let spell, let cardIndex) = targetingMode else { return }
        guard boardIndex < player.board.count else { return }
        guard cardIndex < player.hand.count else { return }

        let card = player.hand [cardIndex]
        let cost = player.effectiveManaCost (card)
        player.spendMana (cost)
        player.hand.remove (at: cardIndex)
        selectedCardIndex = nil
        targetingMode = .none

        switch spell {
        case "Prometheus's Fire":
            // Temporary +2 attack — only `currentAttack` is modified.
            player.board [boardIndex].currentAttack = (player.board [boardIndex].currentAttack ?? 0) + 2
            log ("Prometheus's Fire gives \(player.board [boardIndex].name) +2 attack!")
            let fireID = player.board [boardIndex].id
            fireCreatureIDs.insert (fireID)

        case "Shield of Sparta":
            // Permanent +3 health — both `currentHealth` and base `health` are
            // raised so the creature keeps the bonus after turn-end health reset.
            player.board [boardIndex].currentHealth = (player.board [boardIndex].currentHealth ?? 0) + 3
            player.board [boardIndex].health = (player.board [boardIndex].health ?? 0) + 3
            log ("Shield of Sparta gives \(player.board [boardIndex].name) +3 health!")

        default:
            break
        }
        player.discard.append (card)
        checkWinCondition ()
    }

    /// Resolves spells and creature abilities that target a single opponent creature.
    ///
    /// Called when the player taps an opponent's board creature while in
    /// `.selectingOpponentCreature` mode. The `spell` value in the targeting
    /// case disambiguates which effect to apply, since multiple different spells
    /// and creature abilities share this same targeting mode.
    ///
    /// Heracles is included here despite being a creature card — his destroy
    /// ability targets an opponent creature on entry and shares the same
    /// interaction pattern as targeted spells.
    func selectOpponentTarget (boardIndex: Int) {
        guard case .selectingOpponentCreature (let spell, let cardIndex) = targetingMode else { return }
        guard boardIndex < opponent.board.count else { return }
        guard cardIndex < player.hand.count else { return }

        let card = player.hand [cardIndex]
        let cost = player.effectiveManaCost (card)

        switch spell {
        case "Sisyphus's Burden":
            // Prevent the targeted creature from attacking next turn by registering
            // its ID in `burdenedCreatureIDs`. Setting `canAttack = false` here also
            // stops it attacking for the remainder of the current opponent turn if
            // this spell is cast reactively; `endTurn` will then honour the burden
            // flag to skip the next `canAttack = true` reset.
            player.spendMana (cost)
            player.hand.remove (at: cardIndex)
            let burdenedID = opponent.board [boardIndex].id
            opponent.board [boardIndex].canAttack = false
            burdenedCreatureIDs.insert (burdenedID)
            player.discard.append (card)
            log ("Sisyphus's Burden stops \(opponent.board [boardIndex].name) from attacking next turn!")
            selectedCardIndex = nil
            targetingMode = .none

        case "Curse of Circe":
            // Replace the targeted creature in-place with a 1/1 Pig token.
            // The pig inherits `canAttack` from the transformed creature so there
            // is no unintended summoning sickness if the creature was already ready.
            player.spendMana (cost)
            player.hand.remove (at: cardIndex)
            let transformedName = opponent.board [boardIndex].name
            var pig = Card (name: "Pig", type: .monster, manaCost: 1, imageName: "pig", description: "A transformed 1/1 pig.", attack: 1, health: 1)
            pig.canAttack = opponent.board [boardIndex].canAttack
            opponent.discard.append (opponent.board [boardIndex])
            opponent.board [boardIndex] = pig
            // If the transformed creature was Ares, remove his +1 bonus from the board
            if transformedName == "Ares" {
                for i in opponent.board.indices where opponent.board[i].name != "Pig" || i != boardIndex {
                    opponent.board[i].currentAttack? -= 1
                }
            }
            player.discard.append (card)
            log ("Curse of Circe transforms an enemy into a pig!")
            selectedCardIndex = nil
            targetingMode = .none

        case "Heracles":
            // Guard: only valid targets (health ≤ 2) should be selectable, but
            // re-check here in case the board changed between targeting and resolution.
            guard (opponent.board [boardIndex].currentHealth ?? 0) <= 2 else {
                log ("That creature has more than 2 health.")
                return
            }
            player.spendMana (cost)
            let name = opponent.board [boardIndex].name
            // Move the destroyed creature to the opponent's discard before removing it.
            opponent.discard.append (opponent.board [boardIndex])
            opponent.board.remove (at: boardIndex)
            player.hand.remove (at: cardIndex)
            // Place Heracles himself onto the board after his ability resolves.
            var played = card
            played.canAttack = false
            if player.hasAres () { played.currentAttack = (played.currentAttack ?? 0) + 1 }
            player.board.append (played)
            log ("Heracles destroys \(name)!")
            selectedCardIndex = nil
            targetingMode = .none

        default:
            break
        }
        checkWinCondition ()
    }

    /// Resolves the Lightning Bolt spell against either a chosen creature or the
    /// opponent hero directly.
    ///
    /// - Parameters:
    ///   - boardIndex: The index of the opponent creature to hit, or `nil` when
    ///     targeting the hero.
    ///   - targetHero: `true` when the player tapped the "Bolt Hero" button in
    ///     `ControlBarView` rather than selecting a creature.
    ///
    /// Poseidon's passive — "your creatures can't be targeted by spells" — is
    /// checked here before applying creature damage. The hero bypass is intentional:
    /// Poseidon protects his own creatures, not himself.
    func selectLightningTarget (boardIndex: Int? = nil, targetHero: Bool = false) {
        guard case .selectingLightningTarget (let cardIndex) = targetingMode else { return }
        guard cardIndex < player.hand.count else { return }

        let card = player.hand [cardIndex]
        let cost = player.effectiveManaCost (card)
        player.spendMana (cost)
        player.hand.remove (at: cardIndex)
        player.discard.append (card)
        selectedCardIndex = nil
        targetingMode = .none

        if targetHero {
            opponent.health -= 3
            log ("Lightning Bolt hits the opponent hero for 3!")
        } else if let bi = boardIndex, bi < opponent.board.count {
            // Poseidon blocks all spells that target his side's creatures.
            if opponent.board.contains (where: { $0.name == "Poseidon" }) {
                log ("Poseidon protects opponent creatures from spells!")
            } else {
                let name = opponent.board [bi].name
                let boltDmg = name == "Achilles" ? 6 : 3   // Double damage to Achilles.
                if name == "Athena" && shieldedCreatureIDs.contains (opponent.board [bi].id) {
                    shieldedCreatureIDs.remove (opponent.board [bi].id)
                    log ("Lightning Bolt hit Athena's Divine Shield!")
                } else {
                    opponent.board [bi].currentHealth = (opponent.board [bi].currentHealth ?? 0) - boltDmg
                    log ("Lightning Bolt hits \(name) for \(boltDmg)!")
                    removeDeadOpponentCreatures ()
                }
            }
        }
        checkWinCondition ()
    }

    /// Resolves the Odysseus on-play card-selection effect.
    ///
    /// The player has chosen one of the two cards peeked from the top of their deck.
    /// The chosen card is added to hand; the other(s) are discarded. Both are then
    /// removed from the front of the deck. Odysseus himself is placed onto the board
    /// as a normal creature after the card choice resolves.
    func resolveOdysseusChoice (_ chosen: Card) {
        guard case .odysseusChoice (let top2, let cardIndex) = targetingMode else { return }
        guard cardIndex < player.hand.count else { return }

        let card = player.hand [cardIndex]
        let cost = player.effectiveManaCost (card)
        player.spendMana (cost)
        player.hand.remove (at: cardIndex)

        let kept      = top2.first { $0.id == chosen.id }
        let discarded = top2.filter { $0.id != chosen.id }

        // Remove the peeked cards from the actual deck now that the choice is made.
        player.deck.removeFirst (min (top2.count, player.deck.count))

        if let k = kept { player.hand.append (k) }
        for d in discarded { player.discard.append (d) }

        // Place Odysseus onto the board — he doesn't attack the turn he's played.
        var played = card
        played.canAttack = false
        if player.hasAres () { played.currentAttack = (played.currentAttack ?? 0) + 1 }
        player.board.append (played)
        log ("Odysseus: you kept \(chosen.name)!")
        selectedCardIndex = nil
        targetingMode = .none
        checkWinCondition ()
    }

    /// Resolves the Necromancy spell's creature revival selection.
    ///
    /// The chosen creature is removed from the player's discard pile, its stats
    /// reset to base values (as if freshly drawn), and placed onto the board with
    /// summoning sickness. The Necromancy card itself is moved to discard.
    func resolveNecromancyChoice (_ chosen: Card) {
        guard case .necromancyChoice (_, let cardIndex) = targetingMode else { return }
        guard cardIndex < player.hand.count else { return }

        let card = player.hand [cardIndex]
        let cost = player.effectiveManaCost (card)
        player.spendMana (cost)
        player.hand.remove (at: cardIndex)

        // Remove the chosen creature from the discard pile using its unique ID.
        if let i = player.discard.firstIndex (where: { $0.id == chosen.id }) {
            player.discard.remove (at: i)
        }

        // Reset the revived creature's stats to full base values.
        var revived = chosen
        revived.currentHealth = chosen.health
        revived.currentAttack = chosen.attack
        revived.canAttack = false   // Summoning sickness applies even to revived creatures.
        if revived.name == "Perseus" { revived.canAttack = true }
        if revived.name == "Athena"  { revived.id = UUID ().uuidString; shieldedCreatureIDs.insert (revived.id) }
        if player.hasAres () { revived.currentAttack = (revived.currentAttack ?? 0) + 1 }
        // If the revived creature IS Ares, grant +1 attack to all existing board creatures.
        if revived.name == "Ares" {
            for i in player.board.indices {
                player.board [i].currentAttack = (player.board [i].currentAttack ?? 0) + 1
            }
        }
        player.board.append (revived)
        player.discard.append (card)
        log ("Necromancy revives \(revived.name)!")
        selectedCardIndex = nil
        targetingMode = .none
        checkWinCondition ()
    }

    // MARK: - Spell Resolution (Shared)

    /// Resolves spells that take effect immediately without targeting (e.g.
    /// area damage, draw, healing, token summoning).
    ///
    /// Uses `inout` parameters (`active` and `passive`) rather than referencing
    /// `player` and `opponent` directly so the same function can be called for
    /// both player-cast and AI-cast spells without duplicating logic. `active` is
    /// the caster; `passive` is the opponent receiving the effect.
    func resolveSpell (_ card: Card, for active: inout Player, against passive: inout Player) {
        switch card.name {
        case "Poseidon's Tide":
            // Blocked entirely if the opponent's Poseidon is on the board.
            if passive.board.contains (where: { $0.name == "Poseidon" }) {
                log ("Poseidon protects all creatures — Tide blocked!")
            } else {
                for i in passive.board.indices {
                    let dmg = passive.board [i].name == "Achilles" ? 4 : 2
                    if passive.board [i].name == "Athena" && shieldedCreatureIDs.contains (passive.board [i].id) {
                        shieldedCreatureIDs.remove (passive.board [i].id)
                        log ("Poseidon's Tide hit Athena's Divine Shield!")
                    } else {
                        passive.board [i].currentHealth = (passive.board [i].currentHealth ?? 0) - dmg
                    }
                }
                removeDeadCreatures (for: &passive, healingOwner: &active)
                log ("Poseidon's Tide deals 2 to all enemy creatures!")
            }

        case "Oracle's Vision":
            active.drawCard ()
            active.drawCard ()
            log ("Oracle's Vision draws 2 cards!")

        case "Olympian Blessing":
            active.health += 5
            log ("Olympian Blessing heals for 5!")

        case "Trojan Horse":
            // Summon three 1/1 Soldier tokens. Tokens respect the Ares passive.
            for _ in 0..<3 {
                var s = Card (name: "Soldier", type: .monster, manaCost: 1, imageName: "soldier", description: "A 1/1 Trojan soldier.", attack: 1, health: 1)
                s.canAttack = false
                if active.hasAres () { s.currentAttack = (s.currentAttack ?? 0) + 1 }
                active.board.append (s)
            }
            log ("Trojan Horse summons three 1/1 soldiers!")

        default:
            break
        }
        active.discard.append (card)
        checkWinCondition ()
    }

    // MARK: - Combat

    /// Sets the player's chosen attacker and logs a prompt to pick a target.
    ///
    /// Enforces that: (a) it is the player's turn, (b) the index is valid, and
    /// (c) the creature has `canAttack == true`. If the creature is still under
    /// summoning sickness, a message is shown and the selection is rejected.
    func selectAttacker (at index: Int) {
        guard isPlayerTurn else { return }
        guard index < player.board.count else { return }
        guard player.board [index].canAttack else {
            log ("\(player.board [index].name) can't attack yet.")
            return
        }
        attackerIndex = index
        selectedCardIndex = nil   // Clear any hand selection to prevent conflicting state.
        targetingMode = .none
        log ("Selected \(player.board [index].name). Tap a target.")
    }

    /// Resolves combat between one of the player's creatures (the attacker) and
    /// one of the opponent's creatures (the defender).
    ///
    /// Combat is simultaneous: both creatures deal their current attack as damage
    /// to the other's current health in the same resolution step. Several special
    /// abilities modify this flow:
    ///
    /// - **Minotaur (Taunt):** Forces all attacks to target the Minotaur first.
    /// - **Achilles:** Deals and receives double damage.
    /// - **Leonidas:** Halves incoming damage to adjacent creatures (min 1).
    /// - **Medusa:** Any creature that attacks her is immediately destroyed,
    ///   regardless of whether Medusa survives the hit.
    /// - **Athena (Divine Shield):** Absorbs the first hit at full health with
    ///   no damage, then loses the shield (base health is permanently reduced by 1).
    func attackCreature (attackerIdx: Int, defenderIdx: Int) {
        guard attackerIdx < player.board.count, defenderIdx < opponent.board.count else { return }

        // Minotaur taunt: redirect to Minotaur if the player isn't already targeting it.
        if opponent.board.contains (where: { $0.name == "Minotaur" }) && opponent.board [defenderIdx].name != "Minotaur" {
            log ("The Minotaur must be attacked first!")
            return
        }

        let atkName = player.board [attackerIdx].name
        let defName = opponent.board [defenderIdx].name

        // Resolve base damage values, then apply modifiers.
        var atkDmg = player.board [attackerIdx].currentAttack ?? 0
        var defDmg = opponent.board [defenderIdx].currentAttack ?? 0

        // Achilles deals double damage AND takes double damage in return.
        // When Achilles is the attacker: atkDmg doubles (he hits harder) and
        // defDmg doubles (he is more vulnerable).
        // When Achilles is the defender: atkDmg doubles (he takes double incoming
        // damage) and defDmg doubles (he hits back harder).
        if atkName == "Achilles" { atkDmg *= 2; defDmg *= 2 }
        if defName == "Achilles" { atkDmg *= 2; defDmg *= 2 }

        // Leonidas halves damage to adjacent creatures (min 1 to prevent zero-damage trades).
        if leonidasProtects (index: defenderIdx, on: opponent.board) { atkDmg = max (1, atkDmg / 2) }
        if leonidasProtects (index: attackerIdx, on: player.board)   { defDmg = max (1, defDmg / 2) }

        // Medusa: the attacking creature is destroyed outright. Medusa still takes
        // the attacker's damage, so she can be killed if the attacker hits hard enough.
        if defName == "Medusa" {
            player.board [attackerIdx].currentHealth = -1   // Force death regardless of stats.
            player.board [attackerIdx].canAttack = false
            opponent.board [defenderIdx].currentHealth = max (-1, (opponent.board [defenderIdx].currentHealth ?? 0) - atkDmg)
            log ("\(atkName) attacks Medusa and is destroyed!")
            removeDeadPlayerCreatures ()
            removeDeadOpponentCreatures ()
            attackerIndex = nil
            checkWinCondition ()
            return
        }

        // Athena Divine Shield (defender): if shield active, entire exchange is negated.
        // Neither side takes any damage. Athena's health NEVER changes for shield purposes.
        if defName == "Athena" && shieldedCreatureIDs.contains (opponent.board [defenderIdx].id) {
            shieldedCreatureIDs.remove (opponent.board [defenderIdx].id)
            player.board [attackerIdx].canAttack = false
            log ("\(atkName) hits Athena's Divine Shield! No damage dealt.")
            attackerIndex = nil
            checkWinCondition ()
            return
        }
        
        // Athena Divine Shield (attacker): Athena deals her full damage but takes
        // zero counter-damage on this first hit. Shield is then permanently removed.
        if atkName == "Athena" && shieldedCreatureIDs.contains (player.board [attackerIdx].id) {
            shieldedCreatureIDs.remove (player.board [attackerIdx].id)
            opponent.board [defenderIdx].currentHealth = max (-1, (opponent.board [defenderIdx].currentHealth ?? 0) - atkDmg)
            player.board [attackerIdx].canAttack = false
            log ("Athena strikes \(defName) for \(atkDmg) — her Divine Shield absorbs the counter-attack!")
            removeDeadOpponentCreatures ()
            attackerIndex = nil
            checkWinCondition ()
            return
        }

        // Standard simultaneous combat: both creatures take damage.
        opponent.board [defenderIdx].currentHealth = max (-1, (opponent.board [defenderIdx].currentHealth ?? 0) - atkDmg)
        player.board [attackerIdx].currentHealth   = max (-1, (player.board [attackerIdx].currentHealth ?? 0) - defDmg)
        player.board [attackerIdx].canAttack = false   // Expend the attacker's action for this turn.

        log ("\(atkName) attacks \(defName)!")
        removeDeadPlayerCreatures ()
        removeDeadOpponentCreatures ()
        attackerIndex = nil
        checkWinCondition ()
    }

    /// Directs a player creature to attack the opponent hero directly.
    ///
    /// Only legal when the opponent's board is empty — the guard enforces
    /// this rule programmatically, matching the "Attack Hero" button's
    /// conditional visibility in `ControlBarView`.
    func attackHero (attackerIdx: Int) {
        guard attackerIdx < player.board.count else { return }
        guard opponent.board.isEmpty else { log ("You must attack creatures first!"); return }

        let name = player.board [attackerIdx].name
        let baseDmg = player.board [attackerIdx].currentAttack ?? 0
        let dmg = name == "Achilles" ? baseDmg * 2 : baseDmg   // Achilles deals double to the hero.
        opponent.health -= dmg
        player.board [attackerIdx].canAttack = false
        log ("\(name) attacks the opponent for \(dmg) damage!")
        attackerIndex = nil
        checkWinCondition ()
    }

    // MARK: - Special Combat Rules

    /// Returns `true` if the creature at `index` on `board` is adjacent to
    /// a Leonidas, indicating it should receive halved incoming damage.
    ///
    /// Adjacency is defined as immediately to the left or right in the board
    /// array, matching the visual layout of `BoardCreatureView` tokens.
    func leonidasProtects (index: Int, on board: [Card]) -> Bool {
        let left  = index > 0               && board [index - 1].name == "Leonidas"
        let right = index < board.count - 1 && board [index + 1].name == "Leonidas"
        return left || right
    }

    // MARK: - Death Checking

    /// Removes all player creatures with health ≤ 0, handles triggered death
    /// effects, and moves dead creatures to the discard pile.
    ///
    /// Death effects resolved here:
    /// - **Hades (opponent's):** Heals the opponent for 2 per player creature that dies.
    /// - **Hydra:** Spawns two 2/1 Hydra Head tokens when it dies.
    ///
    /// Health is capped at 60 for Hades healing to prevent infinite scaling
    /// in edge cases where many creatures die simultaneously.
    func removeDeadPlayerCreatures () {
        let dead = player.board.filter { ($0.currentHealth ?? 0) <= 0 }
        guard !dead.isEmpty else { return }
        // Only trigger Hades heal if Hades himself isn't dying this same batch.
        if opponent.board.contains (where: { $0.name == "Hades" }) {
            let healCount = dead.count
            opponent.health += healCount * 2
            log ("Opponent's Hades gains \(healCount * 2) health from your fallen creatures!")
        }
        var aresDead = false
        for d in dead {
            if d.name == "Ares"  { aresDead = true }
            if d.name == "Hydra" { spawnHydraHeads (for: &player) }
            shieldedCreatureIDs.remove (d.id)
            player.discard.append (d)
        }
        player.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
        if aresDead {
            for i in 0..<player.board.count {
                player.board [i].currentAttack? -= 1
            }
        }
    }

    /// Mirrors `removeDeadPlayerCreatures()` for opponent creatures, with Hades
    /// healing applied to the player instead.
    func removeDeadOpponentCreatures () {
        let dead = opponent.board.filter { ($0.currentHealth ?? 0) <= 0 }
        guard !dead.isEmpty else { return }
        // Only trigger Hades heal if Hades himself isn't dying this same batch.
        let hadesInDeadBatch = dead.contains { $0.name == "Hades" }
        if !hadesInDeadBatch && player.board.contains (where: { $0.name == "Hades" }) {
            let healCount = dead.count
            player.health += healCount * 2
            log ("Hades gains you \(healCount * 2) health!")
        }
        var aresDead = false
        for d in dead {
            if d.name == "Ares"  { aresDead = true }
            if d.name == "Hydra" { spawnHydraHeads (for: &opponent) }
            shieldedCreatureIDs.remove (d.id)
            opponent.discard.append (d)
        }
        opponent.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
        if aresDead {
            for i in 0..<opponent.board.count {
                opponent.board [i].currentAttack? -= 1
            }
        }
    }

    /// Appends two 2/1 Hydra Head tokens to the given player's board when their
    /// Hydra is destroyed. Tokens enter with summoning sickness and inherit the
    /// Ares attack bonus if Ares is in play.
    func spawnHydraHeads (for p: inout Player) {
        for _ in 0..<2 {
            var head = Card (name: "Hydra Head", type: .monster, manaCost: 1, imageName: "hydra_head", description: "A 2/1 Hydra Head.", attack: 2, health: 1)
            head.canAttack = false
            if p.hasAres () { head.currentAttack = (head.currentAttack ?? 0) + 1 }
            p.board.append (head)
        }
        log ("Hydra spawns two 2/1 Hydra Heads!")
    }


    /// Removes dead creatures from `p` and fires death triggers (Hades heal,
    /// Hydra spawning, Ares debuff) on the inout Player values.
    /// Used by the shared `resolveSpell` path where we have inout Players
    /// rather than the concrete `player`/`opponent` properties.
    private func removeDeadCreatures (for p: inout Player, healingOwner owner: inout Player) {
        let dead = p.board.filter { ($0.currentHealth ?? 0) <= 0 }
        guard !dead.isEmpty else { return }
        // Hades on the owner's board heals the owner for each creature that dies.
        if owner.board.contains (where: { $0.name == "Hades" }) {
            owner.health += dead.count * 2
            log ("Hades gains \(dead.count * 2) health!")
        }
        var aresDied = false
        for d in dead {
            if d.name == "Ares"  { aresDied = true }
            if d.name == "Hydra" { spawnHydraHeads (for: &p) }
            p.discard.append (d)
        }
        p.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
        if aresDied {
            for i in p.board.indices { p.board [i].currentAttack? -= 1 }
        }
    }

    // MARK: - Win Condition

    /// Checks both heroes' health and sets `gameResult` if either has reached 0.
    /// Called after every action that could potentially end the game: card plays,
    /// spells, combat, and death effects.
    func checkWinCondition () {
        if opponent.health <= 0 { gameResult = .playerWon;  log ("You win!") }
        else if player.health <= 0 { gameResult = .opponentWon; log ("You lose!") }
    }

    // MARK: - Game Logging

    /// Updates the live message and appends it to the rolling `gameLog`.
    ///
    /// The log is capped at 30 entries by removing the oldest entry when
    /// the limit is exceeded. This prevents unbounded memory growth in very
    /// long matches without requiring a more complex data structure.
    /// Logs a game event.
    ///
    /// - Parameter queued: `true` for AI-turn messages — each is held on screen
    ///   for `messageDisplayDuration` seconds so the player can read what the
    ///   opponent did. `false` (default) for player-turn messages, which display
    ///   instantly with no delay.
    func log (_ message: String, queued: Bool = false) {
        gameLog.append (message)
        if gameLog.count > 30 { gameLog.removeFirst () }
        if queued {
            messageQueue.append (message)
            drainMessageQueue ()
        } else {
            self.message = message
        }
    }

    /// Drains the AI message queue one entry at a time, holding each on screen
    /// for `messageDisplayDuration` seconds before advancing to the next.
    private func drainMessageQueue () {
        guard !isDisplayingMessage, !messageQueue.isEmpty else { return }
        isDisplayingMessage = true
        let next = messageQueue.removeFirst ()
        self.message = next
        DispatchQueue.main.asyncAfter (deadline: .now () + messageDisplayDuration) { [weak self] in
            guard let self = self else { return }
            self.isDisplayingMessage = false
            self.drainMessageQueue ()
        }
    }

    // MARK: - AI Turn Orchestration

    func runAITurnWithDelay () {
        DispatchQueue.main.asyncAfter (deadline: .now () + 1.2) { [weak self] in
            guard let self = self, !self.isPlayerTurn else { return }
            self.aiScheduleAllActions ()
        }
    }

    /// Plans the full AI turn — what to play and what to attack — then
    /// schedules each action as a timed closure so the player can watch.
    private func aiScheduleAllActions () {
        // ── Phase 1: plan card plays ─────────────────────────────────────────
        let playPlan      = aiPlanCardPlays ()
        let playInterval: Double = 0.9

        for (nth, handIdx) in playPlan.enumerated () {
            DispatchQueue.main.asyncAfter (deadline: .now () + Double (nth) * playInterval) { [weak self] in
                guard let self = self, !self.isPlayerTurn, self.gameResult == .ongoing else { return }
                self.aiPlayCard (at: handIdx - playPlan.prefix (nth).filter { $0 < handIdx }.count)
            }
        }

        // ── Phase 2: plan attacks ────────────────────────────────────────────
        // Count actual ready attackers now, plus a small buffer for tokens that
        // may be spawned during the play phase (Cerberus → 3 heads, Trojan Horse → 3 soldiers).
        // This replaces the old fixed over-provision of 10 slots, which caused the AI
        // to sit in silence for several seconds on turns where it had few or no attackers.
        let attackStart    = Double (playPlan.count) * playInterval + 0.6
        let attackInterval: Double = 0.9
        let knownAttackers = opponent.board.filter { $0.canAttack }.count
        // Buffer of 4 covers any tokens spawned during the play phase.
        let attackSlots    = knownAttackers + 4

        for nth in 0..<attackSlots {
            DispatchQueue.main.asyncAfter (deadline: .now () + attackStart + Double (nth) * attackInterval) { [weak self] in
                guard let self = self, !self.isPlayerTurn, self.gameResult == .ongoing else { return }
                self.aiExecuteNextAttack ()
            }
        }

        // ── Phase 3: end turn ────────────────────────────────────────────────
        let endMsg   = attackStart + Double (attackSlots) * attackInterval + 0.3
        let endTurnT = endMsg + 0.8
        DispatchQueue.main.asyncAfter (deadline: .now () + endMsg) { [weak self] in
            guard let self = self, !self.isPlayerTurn, self.gameResult == .ongoing else { return }
            self.log ("Opponent ends their turn.", queued: true)
        }
        DispatchQueue.main.asyncAfter (deadline: .now () + endTurnT) { [weak self] in
            guard let self = self, !self.isPlayerTurn else { return }
            self.endTurn ()
        }
    }

    // MARK: - AI Card Play Planning

    /// Returns an ordered list of hand indices representing the optimal play
    /// sequence for this turn. Ordering matters because some plays affect what
    /// is subsequently possible (e.g. Ares buffs creatures played after him,
    /// Medea discounts spells played after her, Zeus kills creatures that
    /// were blocking a profitable attack).
    ///
    /// Strategy:
    ///   1. Removal spells first (Circe, Bolt, Burden, Heracles) — clear blockers
    ///      and high-value threats before committing bodies.
    ///   2. AoE clears next (Tide, Zeus) — wipe the board before new creatures enter.
    ///   3. Utility (Oracle, Necromancy, Blessing) — draw, revive, heal.
    ///   4. Enablers (Medea, then Ares) — Medea before more spells, Ares before
    ///      more creatures so new bodies get the +1.
    ///   5. Bodies — all remaining creatures, with high-value first.
    ///   6. Buffs (Fire, Shield, Trojan) — after all creatures are placed.
    private func aiPlanCardPlays () -> [Int] {
        // Simulate the hand to decide which cards to play and in what order,
        // without actually mutating game state.
        var simulatedMana  = opponent.mana
        var remainingHand  = Array (opponent.hand.enumerated ())   // (originalIndex, card)
        var plan: [Int]    = []

        // Helper: assign a sequencing tier (lower = play earlier).
        func tier (_ card: Card) -> Int {
            switch card.name {
            case "Curse of Circe", "Sisyphus's Burden", "Heracles":  return 1   // Targeted removal
            case "Lightning Bolt":                                   return 1   // Removal / face damage
            case "Poseidon's Tide", "Zeus":                          return 2   // AoE clear
            case "Oracle's Vision", "Necromancy":                    return 3   // Card advantage / value
            case "Olympian Blessing":                                return 3   // Healing
            case "Medea":                                            return 4   // Spell discount enabler
            case "Ares":                                             return 5   // Creature buff aura
            case "Achilles", "Perseus":                              return 6   // High-impact bodies
            case "Poseidon", "Athena", "Hades", "Apollo":            return 6   // High-impact gods
            case "Leonidas", "Medusa", "Minotaur", "Hydra":          return 7   // Defensive / tricky bodies
            case "Trojan Horse":                                     return 8   // Buff / token flood
            case "Prometheus's Fire", "Shield of Sparta":            return 8   // Buffs — last
            default:                                                 return 7
            }
        }

        // Greedy selection: repeatedly pick the highest-priority affordable card.
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            // Re-score every remaining card, accounting for simulated Medea/Ares on board.
            let hasMedeaInPlan = plan.contains { opponent.hand [$0].name == "Medea" }
                || opponent.board.contains { $0.name == "Medea" }
            let affordable = remainingHand.filter { (_, card) in
                let cost = (card.type == .spell && hasMedeaInPlan)
                    ? max (0, card.manaCost - 1) : card.manaCost
                return simulatedMana >= cost
            }
            guard !affordable.isEmpty else { break }

            // Sort by: (tier ASC, priority score DESC).
            let sorted = affordable.sorted { a, b in
                let ta = tier (a.1), tb = tier (b.1)
                if ta != tb { return ta < tb }
                return aiCardPriority (a.1) > aiCardPriority (b.1)
            }

            if let (origIdx, card) = sorted.first {
                let cost = (card.type == .spell && hasMedeaInPlan)
                    ? max (0, card.manaCost - 1) : card.manaCost
                simulatedMana -= cost
                plan.append (origIdx)
                remainingHand.removeAll { $0.0 == origIdx }
                keepGoing = true
            }
        }
        return plan
    }

    /// Plays exactly the next card determined by aiScheduleAllActions.
    /// Re-selecting is handled by the caller adjusting the index.
    private func aiPlayNextCard () {
        let sorted = opponent.hand.indices
            .filter { opponent.mana >= opponent.effectiveManaCost (opponent.hand [$0]) }
            .sorted { aiCardPriority (opponent.hand [$0]) > aiCardPriority (opponent.hand [$1]) }
        guard let idx = sorted.first else { return }
        aiPlayCard (at: idx)
        checkWinCondition ()
    }

    // MARK: - AI Card Priority Scoring

    /// Assigns a context-sensitive priority score to a card, used both for
    /// play-order sorting and as part of the planning heuristic.
    ///
    /// Scores are calibrated so:
    ///   > 100  : must-play this turn (lethal setup, critical removal)
    ///   60-100 : strong play
    ///   30-60  : reasonable play
    ///   < 0    : do not play (no valid target, or strictly worse than holding)
    func aiCardPriority (_ card: Card) -> Int {
        let myBoard        = opponent.board
        let theirBoard     = player.board
        let myHP           = opponent.health
        let theirHP        = player.health
        let myHandSize     = opponent.hand.count
        let myBoardCount   = myBoard.count
        var score          = 0

        // ── Pre-compute useful board facts ───────────────────────────────────
        let theirTotalAtk  = theirBoard.filter { $0.canAttack }.reduce (0) { $0 + ($1.currentAttack ?? 0) }
        let myTotalAtk     = myBoard.filter    { $0.canAttack }.reduce (0) { $0 + ($1.currentAttack ?? 0) }
        let theirBoardCount = theirBoard.count
        let hasPoseidon    = theirBoard.contains { $0.name == "Poseidon" }
        let hasMedusa      = theirBoard.contains { $0.name == "Medusa" }
        let _ = myBoard.contains { $0.name == "Poseidon" }   // myPoseidon (unused but kept for symmetry)

        // ── Am I being threatened? ───────────────────────────────────────────
        // If the player can kill me next turn by going face, that changes priorities.
        let lethalThreat   = theirTotalAtk >= myHP
        let nearLethal     = theirTotalAtk >= myHP - 5

        // ── Can I kill the player this turn + next? ──────────────────────────
        let canGoFaceNow   = theirBoard.isEmpty && myTotalAtk >= theirHP

        switch card.name {

        // ── REMOVAL / BOARD CONTROL ──────────────────────────────────────────

        case "Curse of Circe":
            if hasPoseidon { score = -10; break }
            if hasMedusa   { score = 140; break }   // Remove Medusa without losing a creature.
            if let best = theirBoard.max (by: { (($0.currentAttack ?? 0) + ($0.currentHealth ?? 0)) <
                                               (($1.currentAttack ?? 0) + ($1.currentHealth ?? 0)) }) {
                let combined = (best.currentAttack ?? 0) + (best.currentHealth ?? 0)
                let urgency  = lethalThreat ? 30 : (nearLethal ? 15 : 0)
                score = 80 + combined * 6 + urgency
            } else {
                score = -10
            }

        case "Sisyphus's Burden":
            if hasPoseidon { score = -10; break }
            // Strongest use: silence a creature that is about to deal lethal to me.
            let readyThreats = theirBoard.filter { $0.canAttack }
            let allThreats   = theirBoard
            // Exclude creatures we can already kill this turn.
            let myMaxAtk = myBoard.filter { $0.canAttack }.map { $0.currentAttack ?? 0 }.max () ?? 0
            let nonKillable = readyThreats.filter { ($0.currentHealth ?? 0) > myMaxAtk }
            let pool = nonKillable.isEmpty ? allThreats : nonKillable
            if let best = pool.max (by: { ($0.currentAttack ?? 0) < ($1.currentAttack ?? 0) }) {
                let atk = best.currentAttack ?? 0
                let readyBonus = best.canAttack ? 25 : 0
                let urgencyBonus = lethalThreat ? 40 : (nearLethal ? 20 : 0)
                score = 50 + atk * 8 + readyBonus + urgencyBonus
            } else {
                score = -10
            }

        case "Lightning Bolt":
            if hasPoseidon {
                // Face damage only — worthwhile if we're near lethal on them.
                score = (theirHP <= 6) ? 90 : (theirHP <= 12 ? 50 : 15)
                break
            }
            if hasMedusa {
                // Bolt Medusa — 3 damage softens her (4 hp), leaving her at 1 hp.
                // If she's already at 3 or less, bolt kills her.
                let medusaHp = theirBoard.first (where: { $0.name == "Medusa" })?.currentHealth ?? 4
                score = medusaHp <= 3 ? 130 : 85
                break
            }
            // Kill a high-value threat.
            let boltKillable = theirBoard.filter {
                let hp = $0.currentHealth ?? 0
                let dmg = $0.name == "Achilles" ? 6 : 3
                return !shieldedCreatureIDs.contains ($0.id) && hp <= dmg
            }
            if let bestKill = boltKillable.max (by: { ($0.currentAttack ?? 0) < ($1.currentAttack ?? 0) }) {
                let threatValue = (bestKill.currentAttack ?? 0) * 8
                let urgency = lethalThreat ? 30 : 0
                score = 90 + threatValue + urgency
            } else if theirHP <= 6 {
                score = 88   // Near-lethal: go face.
            } else if theirHP <= 12 {
                // Chip face damage if nothing better.
                let chipValue = theirBoard.isEmpty ? 60 : 20
                score = chipValue
            } else {
                score = -10   // Hold — no good target.
            }

        case "Poseidon's Tide":
            if hasPoseidon { score = -10; break }
            let tideKills = theirBoard.filter {
                let hp  = $0.currentHealth ?? 0
                let dmg = $0.name == "Achilles" ? 4 : 2
                return !shieldedCreatureIDs.contains ($0.id) && hp <= dmg
            }
            let killCount = tideKills.count
            let totalDmg  = theirBoard.reduce (0) { $0 + min (($1.currentHealth ?? 0), ($1.name == "Achilles" ? 4 : 2)) }
            if killCount > 0 {
                // Bonus for wiping the whole board.
                let wipeBonus = (killCount == theirBoardCount && theirBoardCount >= 2) ? 40 : 0
                score = 55 + killCount * 22 + wipeBonus
            } else if theirBoardCount >= 3 {
                // Even without kills: damaging a wide board is tempo.
                score = 35 + totalDmg * 3
            } else {
                score = -10
            }

        // ── CARD ADVANTAGE ───────────────────────────────────────────────────

        case "Oracle's Vision":
            // More urgent when hand is thin; less urgent when already flooded.
            score = myHandSize <= 2 ? 70 : (myHandSize <= 4 ? 45 : 22)

        case "Necromancy":
            let best = opponent.discard.filter { $0.type != .spell }
                .max (by: { (($0.attack ?? 0) + ($0.health ?? 0)) < (($1.attack ?? 0) + ($1.health ?? 0)) })
            if let b = best {
                let power = (b.attack ?? 0) + (b.health ?? 0)
                // Named high-value resurrections.
                let nameBonus: Int
                switch b.name {
                case "Zeus", "Ares":      nameBonus = 30
                case "Hades", "Poseidon": nameBonus = 20
                case "Athena":            nameBonus = 25   // Returns with shield.
                case "Achilles":          nameBonus = 15
                default:                  nameBonus = 0
                }
                score = 65 + power * 5 + nameBonus
            } else {
                score = -10
            }

        case "Olympian Blessing":
            if lethalThreat { score = 120; break }   // Emergency: must heal to survive.
            if myHP <= 10   { score = 100; break }
            if myHP <= 18   { score = 72  }
            else if myHP <= 25 { score = 35 }
            else               { score = 12 }   // Mild top-off: low priority.

        // ── ENABLERS ─────────────────────────────────────────────────────────

        case "Medea":
            let spells = opponent.hand.filter { $0.type == .spell }.count
            score = 55 + spells * 9   // More spells in hand = more value.

        case "Trojan Horse":
            // Three 1/1s: good for flooding when board is thin, less so when already wide.
            let boardRoom = 7 - myBoardCount   // Assume max board size ~7.
            score = boardRoom >= 3 ? 50 : (boardRoom >= 1 ? 30 : -10)

        case "Prometheus's Fire":
            let readyAttackers = myBoard.filter { $0.canAttack }
            if let best = readyAttackers.max (by: { ($0.currentAttack ?? 0) < ($1.currentAttack ?? 0) }) {
                let atk = best.currentAttack ?? 0
                // Most valuable when the +2 lets this attacker kill something it otherwise couldn't.
                let unlockBonus = theirBoard.filter {
                    let hp = $0.currentHealth ?? 0
                    return hp > atk && hp <= atk + 2
                }.count * 20
                score = 45 + atk * 5 + unlockBonus
            } else {
                score = -10   // No ready attackers — useless this turn.
            }

        case "Shield of Sparta":
            if let best = myBoard.max (by: { ($0.currentAttack ?? 0) < ($1.currentAttack ?? 0) }) {
                let atk = best.currentAttack ?? 0
                // More valuable on high-attack creatures (they're worth protecting).
                // Extra value when shielded creature would otherwise die to opponent's attacks.
                let survivalBonus = theirTotalAtk > (best.currentHealth ?? 0) ? 25 : 0
                score = 35 + atk * 7 + survivalBonus
            } else {
                score = 5
            }

        // ── CREATURES ────────────────────────────────────────────────────────

        case "Zeus":
            let zeusDmg: (Card) -> Int = { c in c.name == "Achilles" ? 4 : 2 }
            let zeusKills = theirBoard.filter {
                !shieldedCreatureIDs.contains ($0.id) && ($0.currentHealth ?? 0) <= zeusDmg ($0)
            }.count
            let zeusWeakens = theirBoard.filter {
                !shieldedCreatureIDs.contains ($0.id) && ($0.currentHealth ?? 0) > zeusDmg ($0)
            }.count
            score = 72 + zeusKills * 24 + zeusWeakens * 6

        case "Ares":
            // Extraordinarily good with creatures already on board.
            score = myBoardCount >= 3 ? 95 : (myBoardCount >= 1 ? 78 : 58)

        case "Hades":
            let dyingThisBoard = (theirBoard + myBoard).filter { ($0.currentHealth ?? 0) <= 3 }.count
            let hasBoardPressure = theirBoardCount >= 2
            score = 70 + dyingThisBoard * 8 + (hasBoardPressure ? 15 : 0)

        case "Poseidon":
            // More valuable when we have many creatures to protect.
            score = 65 + myBoardCount * 6

        case "Athena":
            // Divine Shield is free damage prevention — always strong.
            score = 75

        case "Apollo":
            let healUrgency = lethalThreat ? 20 : (nearLethal ? 10 : 0)
            score = (myHP <= 20 ? 78 : 62) + healUrgency

        case "Heracles":
            if hasPoseidon {
                score = 32   // Enters as plain 4/4.
            } else {
                let targets = theirBoard.filter { ($0.currentHealth ?? 0) <= 2 }
                if let best = targets.max (by: { ($0.currentAttack ?? 0) < ($1.currentAttack ?? 0) }) {
                    score = 85 + (best.currentAttack ?? 0) * 10
                } else {
                    score = 22   // No valid target.
                }
            }

        case "Achilles":
            // Devastating when opponent board is thin or empty (can swing face).
            // Dangerous when opponent has big creatures.
            let faceValue = theirBoard.isEmpty ? 40 : 0
            let killValue = theirBoard.filter { ($0.currentHealth ?? 0) <= 10 }.count * 10
            score = 65 + faceValue + killValue

        case "Odysseus":
            score = myHandSize <= 3 ? 65 : 48

        case "Perseus":
            // Charge: attacks immediately. Strong when we need board presence or can go face.
            let faceBonus = theirBoard.isEmpty ? 25 : 0
            score = 68 + faceBonus

        case "Leonidas":
            // Protects adjacent creatures — huge value when we have a wide board.
            score = myBoardCount >= 2 ? 62 : (myBoardCount >= 1 ? 50 : 38)

        case "Minotaur":
            score = 52

        case "Medusa":
            // Deters attacks entirely — very strong when opponent has attackers.
            let deterValue = theirBoard.filter { $0.canAttack }.count * 12
            score = 48 + deterValue

        case "Hydra":
            // 4/3 that becomes 2× 2/1 on death — great tempo.
            score = 58

        case "Cerberus":
            // 3× 2/2: floods the board. More valuable when board is empty.
            score = myBoardCount == 0 ? 65 : 50

        case "Cyclops":
            score = 46

        case "Harpy":
            // Only worth playing early or when mana-starved.
            score = (opponent.mana <= 2) ? 38 : 22

        default:
            let statValue = (card.attack ?? 0) + (card.health ?? 0) - card.manaCost
            score = 30 + statValue * 6
        }

        // ── Global adjustments ───────────────────────────────────────────────

        // Urgency: if I'm about to die and this card can stabilise, boost it heavily.
        if lethalThreat && (card.name == "Olympian Blessing" || card.name == "Apollo") {
            score += 50
        }

        // Cantrip bonus: if we're flooding and card draws more, penalise less.
        if canGoFaceNow && card.type != .spell { score -= 10 }   // Don't flood board when lethal is ready.

        return score
    }

    // MARK: - AI Attack Execution

    /// Executes the single best attack available this turn.
    ///
    /// Priority order:
    /// 1. Lethal: if total face damage kills the player hero right now, attack face.
    /// 2. Lethal setup: if removing a specific blocker clears the path for lethal
    ///    next attack, remove that blocker first.
    /// 3. Best (attacker, target) pair by `tradeScore`.
    func aiExecuteNextAttack () {
        guard !isPlayerTurn else { return }

        let attackable = opponent.board.indices.filter { opponent.board [$0].canAttack }
        guard !attackable.isEmpty else { return }

        // ── 1. Pure face lethal ──────────────────────────────────────────────
        if player.board.isEmpty {
            if let atkIdx = aiChooseBestAttacker (from: attackable) {
                aiAttackHero (attackerIdx: atkIdx)
            }
            return
        }

        // ── 2. Check if killing any specific creature enables face lethal ────
        //    For each target: simulate kill → compute remaining face damage → check lethal.
        if let (atkIdx, defIdx) = aiFindLethalSetupAttack (from: attackable) {
            aiAttackCreature (attackerIdx: atkIdx, defenderIdx: defIdx)
            return
        }

        // ── 3. Best trade on the board ───────────────────────────────────────
        if let (atkIdx, defIdx) = aiBestAttackPair (from: attackable) {
            aiAttackCreature (attackerIdx: atkIdx, defenderIdx: defIdx)
            return
        }

        // ── 4. No profitable trade — still go face if board is now clear ─────
        //    (can happen if previous attacks cleared the board this turn)
        if player.board.isEmpty, let atkIdx = aiChooseBestAttacker (from: attackable) {
            aiAttackHero (attackerIdx: atkIdx)
        }
    }

    /// Checks whether any attack this turn can kill a creature that, once dead,
    /// would leave the remaining attackers able to deal lethal face damage.
    ///
    /// Example: player has a 1/3. AI has a 4/4 and a 3/3. Combined face dmg = 7.
    /// If player HP = 7, removing the 1/3 with the 4/4 lets the 3/3 go face for 3.
    /// Not lethal yet — but if player HP = 3, removing the blocker first is right.
    ///
    /// Returns the (attacker, target) that sets up lethal, or nil.
    private func aiFindLethalSetupAttack (from attackable: [Int]) -> (Int, Int)? {
        let playerHP = player.health

        for atkIdx in attackable {
            for defIdx in player.board.indices {
                let score = tradeScore (atkIdx: atkIdx, defIdx: defIdx)
                guard score > -100 else { continue }   // Skip Medusa suicides unless only option.

                // Simulate: if this attacker kills the target, what is the remaining face damage?
                let atkAtk = opponent.board [atkIdx].currentAttack ?? 0
                let defHP  = player.board [defIdx].currentHealth ?? 0
                let atkName = opponent.board [atkIdx].name
                let defName = player.board [defIdx].name

                var effectiveAtk = atkAtk
                if atkName == "Achilles" { effectiveAtk *= 2 }
                if defName == "Achilles" { effectiveAtk *= 2 }
                if leonidasProtects (index: defIdx, on: player.board) { effectiveAtk = max (1, effectiveAtk / 2) }
                let athenaShielded = defName == "Athena" && shieldedCreatureIDs.contains (player.board [defIdx].id)
                let kills = !athenaShielded && effectiveAtk >= defHP

                guard kills else { continue }   // Only consider attacks that actually kill.

                // Remaining attackers after this one is used.
                let remainingAttackers = attackable.filter { $0 != atkIdx }
                let remainingFaceDmg = remainingAttackers.reduce (0) { sum, i in
                    let atk = opponent.board [i].currentAttack ?? 0
                    return sum + (opponent.board [i].name == "Achilles" ? atk * 2 : atk)
                }

                // Remaining blockers after this one dies.
                let remainingBlockers = player.board.count - 1   // This target would be dead.
                if remainingBlockers == 0 && remainingFaceDmg >= playerHP {
                    return (atkIdx, defIdx)   // Found lethal setup!
                }
            }
        }
        return nil
    }

    /// Jointly selects the best (attacker, target) pair from all possible combinations.
    func aiBestAttackPair (from attackable: [Int]) -> (Int, Int)? {
        // Minotaur taunt: forced target.
        if player.board.contains (where: { $0.name == "Minotaur" }),
           let minoIdx = player.board.firstIndex (where: { $0.name == "Minotaur" }) {
            let best = attackable.max (by: { a, b in
                tradeScore (atkIdx: a, defIdx: minoIdx) < tradeScore (atkIdx: b, defIdx: minoIdx)
            })
            guard let atkIdx = best else { return nil }
            // Even vs Minotaur, don't attack if it's pure suicide.
            return tradeScore (atkIdx: atkIdx, defIdx: minoIdx) >= -10 ? (atkIdx, minoIdx) : nil
        }

        var bestScore = Int.min
        var bestPair: (Int, Int)? = nil

        for atkIdx in attackable {
            for defIdx in player.board.indices {
                let s = tradeScore (atkIdx: atkIdx, defIdx: defIdx)
                // Minimum-force tie-break: prefer lower-attack attacker to conserve power.
                let atkAtk = opponent.board [atkIdx].currentAttack ?? 0
                let curAtk = bestPair.map { opponent.board [$0.0].currentAttack ?? 0 } ?? Int.max
                if s > bestScore || (s == bestScore && atkAtk < curAtk) {
                    bestScore = s
                    bestPair  = (atkIdx, defIdx)
                }
            }
        }

        // Minimum threshold: don't attack if the best outcome is still losing the attacker
        // without compensation. Chip damage (-20) is allowed; pure suicide (-30+) is not
        // unless named bonuses pushed the score positive.
        guard bestScore >= -10 else { return nil }
        return bestPair
    }

    /// Scores a single (attacker, target) combat pair from the AI's perspective.
    /// Full accounting: Achilles doubling, Leonidas halving, Athena shield, Medusa, name bonuses.
    private func tradeScore (atkIdx: Int, defIdx: Int) -> Int {
        guard atkIdx < opponent.board.count, defIdx < player.board.count else { return Int.min }

        let atkName  = opponent.board [atkIdx].name
        let defName  = player.board  [defIdx].name
        let myHp     = opponent.board [atkIdx].currentHealth ?? 0
        let defHp    = player.board   [defIdx].currentHealth ?? 0

        var effectiveAtk = opponent.board [atkIdx].currentAttack ?? 0
        var effectiveDef = player.board   [defIdx].currentAttack ?? 0

        if atkName == "Achilles" { effectiveAtk *= 2; effectiveDef *= 2 }
        if defName == "Achilles" { effectiveAtk *= 2; effectiveDef *= 2 }

        if leonidasProtects (index: defIdx, on: player.board)   { effectiveAtk = max (1, effectiveAtk / 2) }
        if leonidasProtects (index: atkIdx, on: opponent.board) { effectiveDef = max (1, effectiveDef / 2) }

        let athenaShielded = defName == "Athena" && shieldedCreatureIDs.contains (player.board [defIdx].id)
        let kills    = !athenaShielded && effectiveAtk >= defHp
        let survives = myHp > effectiveDef

        // Medusa: attacker is instantly destroyed.
        if defName == "Medusa" {
            let onlyMedusa = player.board.allSatisfy { $0.name == "Medusa" }
            if onlyMedusa {
                // Sacrifice weakest to clear the board.
                let weakestAtk = opponent.board.filter { $0.canAttack }
                    .min (by: { ($0.currentAttack ?? 0) < ($1.currentAttack ?? 0) })?.currentAttack ?? 0
                return (effectiveAtk == weakestAtk) ? 5 : -150
            }
            return -150
        }

        var score: Int
        if kills && survives   { score = 100 + (player.board [defIdx].currentAttack ?? 0) * 10 }
        else if kills          { score = 40  + (player.board [defIdx].currentAttack ?? 0) * 5  }
        else if survives       { score = -20 }   // Chip damage — allowed.
        else                   { score = -30 }   // Suicidal — named bonuses may redeem it.

        // Wasting a hit on a shielded Athena breaks shield but deals no damage.
        if athenaShielded    { score = max (score, -40) }

        // Named card threat bonuses.
        if defName == "Zeus"     { score += 40 }   // Removing Zeus before he AoEs next turn is huge.
        if defName == "Ares"     { score += 35 }   // Ares passively pumps everything.
        if defName == "Hades"    { score += 30 }   // Hades heals opponent for every death.
        if defName == "Poseidon" { score += 28 }   // Shutting down spells hurts hard.
        if defName == "Apollo"   { score += 22 }   // Ongoing heal engine.
        if defName == "Achilles" { score += 18 }   // Double-damage threat.
        if defName == "Leonidas" { score += 15 }   // Halving attack is a major tempo swing.

        // Penalise attacking into a shielded Athena unless there is no better option.
        if athenaShielded && kills { score -= 20 }   // It breaks shield but doesn't kill — net loss.

        return score
    }

    /// Selects the highest face-damage attacker (used when player board is empty).
    func aiChooseBestAttacker (from attackable: [Int]) -> Int? {
        guard !attackable.isEmpty else { return nil }
        return attackable.max (by: {
            let dmgA = opponent.board [$0].name == "Achilles"
                ? (opponent.board [$0].currentAttack ?? 0) * 2 : (opponent.board [$0].currentAttack ?? 0)
            let dmgB = opponent.board [$1].name == "Achilles"
                ? (opponent.board [$1].currentAttack ?? 0) * 2 : (opponent.board [$1].currentAttack ?? 0)
            return dmgA < dmgB
        })
    }

    /// Kept for legacy call sites; delegates to `aiBestAttackPair`.
    func aiChooseBestTarget (attackerIdx: Int) -> Int? {
        let attackable = opponent.board.indices.filter { opponent.board [$0].canAttack }
        return aiBestAttackPair (from: attackable).map { $0.1 }
    }

    func aiCanGoLethal (attackerIdx: Int) -> Bool {
        guard player.board.isEmpty else { return false }
        let total = opponent.board.filter { $0.canAttack }.reduce (0) { $0 + ($1.currentAttack ?? 0) }
        return total >= player.health
    }


    // MARK: - AI Card Execution

    /// Plays a single card from the AI's hand at `index`, deducting mana and
    /// placing creatures or resolving spells via the AI-specific handlers.
    ///
    /// Unlike the player's `commitPlay`, AI spell resolution is handled by
    /// `aiResolveSpell(_:)` rather than the shared `resolveSpell(_:for:against:)`
    /// because the AI makes its own targeting decisions (choosing the best creature
    /// to transform, the most threatening creature to silence, etc.) rather than
    /// waiting for player input.
    func aiPlayCard (at index: Int) {
        guard index < opponent.hand.count else { return }
        let card = opponent.hand [index]
        let cost = opponent.effectiveManaCost (card)
        guard opponent.mana >= cost else { return }

        opponent.spendMana (cost)
        opponent.hand.remove (at: index)

        if card.type == .spell {
            aiResolveSpell (card)
        } else {
            var played = card
            played.canAttack = (card.name == "Perseus")   // Perseus has Charge; all others have summoning sickness.
            if opponent.hasAres () && card.name != "Ares" { played.currentAttack = (played.currentAttack ?? 0) + 1 }
            if card.name == "Athena" { shieldedCreatureIDs.insert (played.id) }
            opponent.board.append (played)
            log ("Opponent played \(card.name).", queued: true)
            aiResolvePlayEffect (card)
        }
        checkWinCondition ()
    }

    // MARK: - AI On-Play Effects

    /// Mirrors `resolvePlayerPlayEffect(_:)` for opponent-controlled cards.
    /// Zeus deals 2 to all player creatures; Ares buffs all existing opponent
    /// creatures; Heracles targets the highest-attack player creature with ≤ 2 health;
    /// Cerberus splits into three 2/2 tokens.
    func aiResolvePlayEffect (_ card: Card) {
        switch card.name {
        case "Zeus":
            // Zeus is a CREATURE ability — Poseidon only blocks spells.
            for i in player.board.indices {
                let dmg = player.board [i].name == "Achilles" ? 4 : 2
                if player.board [i].name == "Athena" && shieldedCreatureIDs.contains (player.board [i].id) {
                    shieldedCreatureIDs.remove (player.board [i].id)
                    log ("Opponent's Zeus hits your Athena's Divine Shield!", queued: true)
                } else {
                    player.board [i].currentHealth = (player.board [i].currentHealth ?? 0) - dmg
                }
            }
            removeDeadPlayerCreatures ()

        case "Ares":
            for i in opponent.board.indices where opponent.board [i].name != "Ares" {
                opponent.board [i].currentAttack = (opponent.board [i].currentAttack ?? 0) + 1
            }

        case "Heracles":
            // Poseidon blocks the destroy ability — Heracles enters as a plain 4/4.
            if player.board.contains (where: { $0.name == "Poseidon" }) {
                log ("Opponent's Heracles is blocked by your Poseidon — enters as a 4/4.", queued: true)
            } else if let t = player.board.indices
                .filter ({ (player.board [$0].currentHealth ?? 0) <= 2 })
                .max (by: { (player.board [$0].currentAttack ?? 0) < (player.board [$1].currentAttack ?? 0) }) {
                // Target highest-attack creature with ≤ 2 health for maximum impact.
                let name = player.board [t].name
                player.discard.append (player.board [t])
                player.board.remove (at: t)
                log ("Opponent's Heracles destroys your \(name)!", queued: true)
            }

        case "Cerberus":
            let idx = opponent.board.count - 1
            opponent.board.remove (at: idx)
            for _ in 0..<3 {
                var h = Card (name: "Cerberus", type: .monster, manaCost: 4, imageName: "cerberus", description: "Summons 3 separate 2/2 creatures instead of one.", attack: 2, health: 2)
                h.canAttack = false
                if opponent.hasAres () { h.currentAttack = (h.currentAttack ?? 0) + 1 }
                opponent.board.append (h)
            }

        case "Odysseus":
            // AI Odysseus simply draws an extra card — no card-picker overlay is needed.
            opponent.drawCard ()

        default:
            break
        }
    }

    // MARK: - AI Spell Resolution

    /// Resolves all spells played by the AI opponent, making targeting decisions
    /// autonomously based on current board state.
    ///
    /// Key AI targeting heuristics:
    /// - **Lightning Bolt**: prefers the highest-attack creature it can kill (health ≤ 3);
    ///   otherwise hits the highest-attack creature for damage; hits the hero as a last resort.
    /// - **Curse of Circe**: targets the highest combined-stat player creature.
    /// - **Sisyphus's Burden**: silences the highest-attack player creature.
    /// - **Shield of Sparta / Prometheus's Fire**: buffs the AI's own highest-attack creature.
    /// - **Necromancy**: revives the highest combined-stat creature from the AI's discard.
    func aiResolveSpell (_ card: Card) {
        switch card.name {
        case "Lightning Bolt":
            if player.board.contains (where: { $0.name == "Poseidon" }) {
                player.health -= 3
                log ("Opponent's Lightning Bolt hits you for 3 (Poseidon blocks creatures)!", queued: true)
                break
            }
            // Medusa: bolt her first — it's the safest removal. She has 4 hp so bolt
            // won't always kill her outright, but it damages her safely for a follow-up.
            if let medusaIdx = player.board.firstIndex (where: { $0.name == "Medusa" }) {
                let newHp = (player.board [medusaIdx].currentHealth ?? 0) - 3
                player.board [medusaIdx].currentHealth = newHp
                if newHp <= 0 {
                    log ("Opponent's Lightning Bolt destroys your Medusa!", queued: true)
                } else {
                    log ("Opponent's Lightning Bolt hits your Medusa for 3!", queued: true)
                }
                removeDeadPlayerCreatures ()
                break
            }
            // Otherwise prefer to kill the highest-attack creature within bolt range.
            let killTarget = player.board.indices.filter { ($0 < player.board.count) && (player.board [$0].currentHealth ?? 0) <= 3 }
                .max (by: { (player.board [$0].currentAttack ?? 0) < (player.board [$1].currentAttack ?? 0) })
            if let t = killTarget {
                let name = player.board [t].name
                let boltDmg = name == "Achilles" ? 6 : 3
                player.board [t].currentHealth = (player.board [t].currentHealth ?? 0) - boltDmg
                log ("Opponent's Lightning Bolt kills \(name)!", queued: true)
                removeDeadPlayerCreatures ()
            } else if !player.board.isEmpty {
                let t = player.board.indices.max (by: { (player.board [$0].currentAttack ?? 0) < (player.board [$1].currentAttack ?? 0) }) ?? 0
                let name = player.board [t].name
                let boltDmg = name == "Achilles" ? 6 : 3
                if name == "Athena" && shieldedCreatureIDs.contains (player.board [t].id) {
                    shieldedCreatureIDs.remove (player.board [t].id)
                    log ("Opponent's Lightning Bolt hits your Athena's Divine Shield!", queued: true)
                } else {
                    player.board [t].currentHealth = (player.board [t].currentHealth ?? 0) - boltDmg
                    log ("Opponent's Lightning Bolt hits \(name) for \(boltDmg)!", queued: true)
                    removeDeadPlayerCreatures ()
                }
            } else {
                player.health -= 3
                log ("Opponent's Lightning Bolt hits you for 3!", queued: true)
            }

        case "Poseidon's Tide":
            // Blocked if the player has Poseidon on the board — same rule as player-cast Tide.
            if player.board.contains (where: { $0.name == "Poseidon" }) {
                log ("Your Poseidon protects your creatures — opponent's Tide is blocked!", queued: true)
            } else {
                for i in player.board.indices {
                    let dmg = player.board [i].name == "Achilles" ? 4 : 2
                    if player.board [i].name == "Athena" && shieldedCreatureIDs.contains (player.board [i].id) {
                        shieldedCreatureIDs.remove (player.board [i].id)
                        log ("Opponent's Poseidon's Tide hits your Athena's Divine Shield!", queued: true)
                    } else {
                        player.board [i].currentHealth = (player.board [i].currentHealth ?? 0) - dmg
                    }
                }
                log ("Opponent's Poseidon's Tide deals 2 to all your creatures!", queued: true)
                removeDeadPlayerCreatures ()
            }

        case "Oracle's Vision":
            opponent.drawCard (); opponent.drawCard ()
            log ("Opponent uses Oracle's Vision to draw 2 cards.", queued: true)

        case "Olympian Blessing":
            opponent.health += 5
            log ("Opponent heals 5 with Olympian Blessing!", queued: true)

        case "Trojan Horse":
            for _ in 0..<3 {
                var s = Card (name: "Soldier", type: .monster, manaCost: 1, imageName: "soldier", description: "A 1/1 Trojan soldier.", attack: 1, health: 1)
                s.canAttack = false
                if opponent.hasAres () { s.currentAttack = (s.currentAttack ?? 0) + 1 }
                opponent.board.append (s)
            }
            log ("Opponent plays Trojan Horse — three soldiers appear!", queued: true)

        case "Shield of Sparta":
            // Buff the AI's highest-attack creature for maximum offensive retention.
            if let i = opponent.board.indices.max (by: { (opponent.board [$0].currentAttack ?? 0) < (opponent.board [$1].currentAttack ?? 0) }) {
                opponent.board [i].currentHealth = (opponent.board [i].currentHealth ?? 0) + 3
                opponent.board [i].health = (opponent.board [i].health ?? 0) + 3
                log ("Opponent's Shield of Sparta buffs \(opponent.board [i].name) with +3 health!", queued: true)
            }

        case "Prometheus's Fire":
            // Only buff a creature that can attack this turn — useless otherwise.
            let fireTargets = opponent.board.indices.filter { opponent.board [$0].canAttack == true }
            if let i = fireTargets.max (by: { (opponent.board [$0].currentAttack ?? 0) < (opponent.board [$1].currentAttack ?? 0) }) {
                opponent.board [i].currentAttack = (opponent.board [i].currentAttack ?? 0) + 2
                log ("Opponent's Prometheus's Fire gives \(opponent.board [i].name) +2 attack!", queued: true)
                let fireID = opponent.board [i].id
                fireCreatureIDs.insert (fireID)
            }

        case "Curse of Circe":
            if player.board.contains (where: { $0.name == "Poseidon" }) {
                log ("Opponent's Curse of Circe fizzles — your Poseidon protects your creatures!", queued: true)
                break
            }
            if !player.board.isEmpty {
                // Medusa: safest Circe target — removes her without losing a creature.
                let medusaIdx = player.board.firstIndex (where: { $0.name == "Medusa" })
                let t = medusaIdx ?? player.board.indices.max (by: {
                    ((player.board [$0].currentAttack ?? 0) + (player.board [$0].currentHealth ?? 0)) <
                    ((player.board [$1].currentAttack ?? 0) + (player.board [$1].currentHealth ?? 0))
                }) ?? 0
                let name = player.board [t].name
                var pig = Card (name: "Pig", type: .monster, manaCost: 1, imageName: "pig", description: "A transformed 1/1 pig.", attack: 1, health: 1)
                pig.canAttack = player.board [t].canAttack   // Preserve the transformed creature's readiness.
                player.discard.append (player.board [t])
                player.board [t] = pig
                // If Ares was transformed, remove his board-wide +1 bonus
                if name == "Ares" {
                    for i in player.board.indices where i != t {
                        player.board[i].currentAttack? -= 1
                    }
                }
                log ("Opponent's Curse of Circe transforms your \(name) into a pig!", queued: true)
            }

        case "Sisyphus's Burden":
            // Poseidon protects player creatures from targeted spells.
            if player.board.contains (where: { $0.name == "Poseidon" }) {
                log ("Opponent's Sisyphus's Burden fizzles — your Poseidon protects your creatures!", queued: true)
                break
            }
            if !player.board.isEmpty {
                let t = player.board.indices.max (by: { (player.board [$0].currentAttack ?? 0) < (player.board [$1].currentAttack ?? 0) }) ?? 0
                let burdenedID = player.board [t].id
                player.board [t].canAttack = false
                burdenedCreatureIDs.insert (burdenedID)
                log ("Opponent's Sisyphus's Burden stops \(player.board [t].name) from attacking next turn!", queued: true)
            }

        case "Necromancy":
            // Revive the highest combined-stat creature from the AI's discard.
            let creatures = opponent.discard.filter { $0.type != .spell }
            if let c = creatures.max (by: { (($0.attack ?? 0) + ($0.health ?? 0)) < (($1.attack ?? 0) + ($1.health ?? 0)) }),
               let di = opponent.discard.lastIndex (where: { $0.id == c.id }) {
                opponent.discard.remove (at: di)
                var revived = c
                revived.currentHealth = c.health
                revived.currentAttack = c.attack
                revived.canAttack = false
                if revived.name == "Perseus" { revived.canAttack = true }
                if revived.name == "Athena"  { revived.id = UUID ().uuidString; shieldedCreatureIDs.insert (revived.id) }
                if opponent.hasAres () { revived.currentAttack = (revived.currentAttack ?? 0) + 1 }
                // If the revived creature IS Ares, grant +1 attack to all existing board creatures.
                if revived.name == "Ares" {
                    for i in opponent.board.indices {
                        opponent.board [i].currentAttack = (opponent.board [i].currentAttack ?? 0) + 1
                    }
                }
                opponent.board.append (revived)
                log ("Opponent's Necromancy revives \(revived.name)!", queued: true)
            }

        default:
            break
        }
        opponent.discard.append (card)
        checkWinCondition ()
    }

    // MARK: - AI Combat Resolution

    /// Executes an AI creature attacking a player creature, applying all the
    /// same special-case combat rules as the player-facing `attackCreature(_:_:)`:
    /// Minotaur taunt, Achilles double damage, Leonidas halving, Medusa retaliation,
    /// and Athena's Divine Shield.
    ///
    /// Keeping the AI on identical combat rules as the player ensures the game
    /// is fair and prevents exploits where the AI could bypass mechanics the
    /// player is subject to.
    func aiAttackCreature (attackerIdx: Int, defenderIdx: Int) {
        guard attackerIdx < opponent.board.count, defenderIdx < player.board.count else { return }

        // Minotaur taunt: force redirection if Minotaur is on the player's board.
        if player.board.contains (where: { $0.name == "Minotaur" }) && player.board [defenderIdx].name != "Minotaur" {
            if let minoIdx = player.board.firstIndex (where: { $0.name == "Minotaur" }) {
                aiAttackCreature (attackerIdx: attackerIdx, defenderIdx: minoIdx)
            }
            return
        }

        let atkName = opponent.board [attackerIdx].name
        let defName = player.board [defenderIdx].name

        var atkDmg = opponent.board [attackerIdx].currentAttack ?? 0
        var defDmg = player.board [defenderIdx].currentAttack ?? 0

        // Achilles deals double AND takes double damage regardless of whether
        // he is the attacker or defender.
        if atkName == "Achilles" { atkDmg *= 2; defDmg *= 2 }
        if defName == "Achilles" { atkDmg *= 2; defDmg *= 2 }

        if leonidasProtects (index: defenderIdx, on: player.board)   { atkDmg = max (1, atkDmg / 2) }
        if leonidasProtects (index: attackerIdx, on: opponent.board) { defDmg = max (1, defDmg / 2) }

        // Medusa destroys any creature that attacks her.
        if defName == "Medusa" {
            opponent.board [attackerIdx].currentHealth = -1
            opponent.board [attackerIdx].canAttack = false
            player.board [defenderIdx].currentHealth = max (-1, (player.board [defenderIdx].currentHealth ?? 0) - atkDmg)
            log ("Opponent's \(atkName) attacks Medusa and is destroyed!", queued: true)
            removeDeadOpponentCreatures ()
            removeDeadPlayerCreatures ()
            checkWinCondition ()
            return
        }

        // Athena Divine Shield (defender): entire exchange negated. No health changes.
        if defName == "Athena" && shieldedCreatureIDs.contains (player.board [defenderIdx].id) {
            shieldedCreatureIDs.remove (player.board [defenderIdx].id)
            opponent.board [attackerIdx].canAttack = false
            log ("Opponent's \(atkName) hits your Athena's Divine Shield! No damage dealt.", queued: true)
            checkWinCondition ()
            return
        }
        
        // Athena Divine Shield (attacker): deals full damage, absorbs counter-attack.
        if atkName == "Athena" && shieldedCreatureIDs.contains (opponent.board [attackerIdx].id) {
            shieldedCreatureIDs.remove (opponent.board [attackerIdx].id)
            player.board [defenderIdx].currentHealth = max (-1, (player.board [defenderIdx].currentHealth ?? 0) - atkDmg)
            opponent.board [attackerIdx].canAttack = false
            log ("Opponent's Athena strikes \(defName) for \(atkDmg) — Divine Shield absorbs counter-attack!", queued: true)
            removeDeadPlayerCreatures ()
            checkWinCondition ()
            return
        }
        
        // Standard simultaneous combat.
        player.board [defenderIdx].currentHealth   = max (-1, (player.board [defenderIdx].currentHealth ?? 0) - atkDmg)
        opponent.board [attackerIdx].currentHealth = max (-1, (opponent.board [attackerIdx].currentHealth ?? 0) - defDmg)
        opponent.board [attackerIdx].canAttack = false

        log ("Opponent's \(atkName) attacks your \(defName)!", queued: true)
        removeDeadPlayerCreatures ()
        removeDeadOpponentCreatures ()
        checkWinCondition ()
    }

    /// Executes an AI creature attacking the player hero directly.
    ///
    /// Guarded against illegal attacks: the player's board must be empty.
    /// `aiExecuteNextAttack` enforces this before calling here, but the guard
    /// is retained as a defensive check.
    func aiAttackHero (attackerIdx: Int) {
        guard attackerIdx < opponent.board.count, player.board.isEmpty else { return }
        let name = opponent.board [attackerIdx].name
        let baseDmg = opponent.board [attackerIdx].currentAttack ?? 0
        let dmg = name == "Achilles" ? baseDmg * 2 : baseDmg   // Achilles deals double to the hero.
        player.health -= dmg
        opponent.board [attackerIdx].canAttack = false
        log ("Opponent's \(name) attacks you for \(dmg) damage!", queued: true)
        checkWinCondition ()
    }

    /// Convenience wrapper that forwards to `Player.effectiveManaCost(_:)` for
    /// a given player instance. Kept for call sites that have a `Player` reference
    /// and want to go through `GameState` for consistency.
    func effectiveManaCost (_ card: Card, for p: Player) -> Int {
        return p.effectiveManaCost (card)
    }
}
