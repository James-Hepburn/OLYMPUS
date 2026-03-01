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
        for i in player.board.indices {
            player.board [i].canAttack = true
            player.board [i].currentHealth = player.board [i].health ?? 0
        }
        for i in opponent.board.indices {
            opponent.board [i].canAttack = true
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
                targetingMode = .selectingOpponentCreature (spell: card.name, cardIndex: index)
                log ("Pick an enemy creature to prevent from attacking.")
                return

            case "Curse of Circe":
                guard !opponent.board.isEmpty else { log ("No enemy creatures."); return }
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
                // Heracles can only target creatures with 2 or less health.
                // If valid targets exist, enter targeting mode; otherwise fall
                // through to play him as a plain creature.
                let validTargets = opponent.board.filter { ($0.currentHealth ?? 0) <= 2 }
                if !validTargets.isEmpty {
                    targetingMode = .selectingOpponentCreature (spell: "Heracles", cardIndex: index)
                    log ("Pick an enemy creature with 2 or less health to destroy.")
                    return
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
            // Zeus deals 2 damage to all opponent creatures on entry.
            for i in opponent.board.indices {
                opponent.board [i].currentHealth = (opponent.board [i].currentHealth ?? 0) - 2
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
            // Prevent the targeted creature from attacking this turn.
            player.spendMana (cost)
            player.hand.remove (at: cardIndex)
            opponent.board [boardIndex].canAttack = false
            player.discard.append (card)
            log ("Sisyphus's Burden stops \(opponent.board [boardIndex].name) from attacking!")
            selectedCardIndex = nil
            targetingMode = .none

        case "Curse of Circe":
            // Replace the targeted creature in-place with a 1/1 Pig token.
            // The pig inherits `canAttack` from the transformed creature so there
            // is no unintended summoning sickness if the creature was already ready.
            player.spendMana (cost)
            player.hand.remove (at: cardIndex)
            var pig = Card (name: "Pig", type: .monster, manaCost: 1, imageName: "pig", description: "A transformed 1/1 pig.", attack: 1, health: 1)
            pig.canAttack = opponent.board [boardIndex].canAttack
            opponent.board [boardIndex] = pig
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
                opponent.board [bi].currentHealth = (opponent.board [bi].currentHealth ?? 0) - 3
                log ("Lightning Bolt hits \(name) for 3!")
                removeDeadOpponentCreatures ()
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
        if player.hasAres () { revived.currentAttack = (revived.currentAttack ?? 0) + 1 }
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
                    passive.board [i].currentHealth = (passive.board [i].currentHealth ?? 0) - 2
                }
                passive.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
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

        // Achilles deals and takes double damage.
        if atkName == "Achilles" { atkDmg *= 2 }
        if defName == "Achilles" { defDmg *= 2 }

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

        // Athena Divine Shield: if Athena is at full base health, the first hit
        // is completely negated. Her base `health` is decremented by 1 to "break"
        // the shield so subsequent hits deal damage normally.
        if defName == "Athena" {
            let athenaCurrent = opponent.board [defenderIdx].currentHealth ?? 0
            let athenaBase    = opponent.board [defenderIdx].health ?? 0
            if athenaCurrent == athenaBase {
                opponent.board [defenderIdx].health = athenaBase - 1   // Break the shield.
                // The attacker still takes counter-damage from Athena.
                player.board [attackerIdx].currentHealth = max (-1, (player.board [attackerIdx].currentHealth ?? 0) - defDmg)
                player.board [attackerIdx].canAttack = false
                log ("\(atkName) hits Athena's Divine Shield!")
                removeDeadPlayerCreatures ()
                attackerIndex = nil
                checkWinCondition ()
                return
            }
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

        let dmg  = player.board [attackerIdx].currentAttack ?? 0
        let name = player.board [attackerIdx].name
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
        if opponent.board.contains (where: { $0.name == "Hades" }) {
            opponent.health = min (opponent.health + dead.count * 2, 60)
        }
        for d in dead {
            if d.name == "Hydra" { spawnHydraHeads (for: &player) }
            player.discard.append (d)
        }
        player.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
    }

    /// Mirrors `removeDeadPlayerCreatures()` for opponent creatures, with Hades
    /// healing applied to the player instead.
    func removeDeadOpponentCreatures () {
        let dead = opponent.board.filter { ($0.currentHealth ?? 0) <= 0 }
        if player.board.contains (where: { $0.name == "Hades" }) {
            player.health = min (player.health + dead.count * 2, 60)
            if dead.count > 0 { log ("Hades gains you \(dead.count * 2) health!") }
        }
        for d in dead {
            if d.name == "Hydra" { spawnHydraHeads (for: &opponent) }
            opponent.discard.append (d)
        }
        opponent.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
    }

    /// Appends two 2/1 Hydra Head tokens to the given player's board when their
    /// Hydra is destroyed. Tokens enter with summoning sickness and inherit the
    /// Ares attack bonus if Ares is in play.
    func spawnHydraHeads (for p: inout Player) {
        for _ in 0..<2 {
            var head = Card (name: "Hydra Head", type: .monster, manaCost: 1, imageName: "hydra", description: "A 2/1 Hydra Head.", attack: 2, health: 1)
            head.canAttack = false
            if p.hasAres () { head.currentAttack = (head.currentAttack ?? 0) + 1 }
            p.board.append (head)
        }
        log ("Hydra spawns two 2/1 Hydra Heads!")
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
    func log (_ message: String) {
        self.message = message
        gameLog.append (message)
        if gameLog.count > 30 { gameLog.removeFirst () }
    }

    // MARK: - AI Turn Orchestration

    /// Schedules the AI's card play phase and attack phase on the main queue
    /// with time-staggered delays, simulating a deliberate opponent.
    ///
    /// The AI acts in two stages:
    /// 1. **Card play** (after `playDelay`): plays all affordable cards in
    ///    priority order via `aiPlayOptimalCards()`.
    /// 2. **Attacks** (after `attackDelay`): executes one creature attack per
    ///    scheduled closure, spaced 0.85 seconds apart so the player can observe
    ///    each attack individually. The closure count is slightly over-provisioned
    ///    (`board.count + 3`) to ensure all attackers get a turn even if tokens
    ///    were summoned during the play phase.
    /// 3. **End turn** (after all attacks): calls `endTurn()` to return control
    ///    to the player.
    ///
    /// All closures capture `self` weakly to prevent a retain cycle in the event
    /// the player quits mid-AI-turn. Each closure also guards `!self.isPlayerTurn`
    /// to short-circuit safely if the game ends before the closure fires.
    func runAITurnWithDelay () {
        let playDelay = 0.8

        DispatchQueue.main.asyncAfter (deadline: .now () + playDelay) { [weak self] in
            guard let self = self, !self.isPlayerTurn else { return }
            self.aiPlayOptimalCards ()
        }

        let attackDelay   = playDelay + 1.4
        let creatureCount = max (opponent.board.count + 3, 6)   // Over-provision for tokens spawned during play.

        for nth in 0..<creatureCount {
            DispatchQueue.main.asyncAfter (deadline: .now () + attackDelay + Double (nth) * 0.85) { [weak self] in
                guard let self = self, !self.isPlayerTurn else { return }
                self.aiExecuteNextAttack ()
            }
        }

        let endDelay = attackDelay + Double (creatureCount) * 0.85 + 0.8
        DispatchQueue.main.asyncAfter (deadline: .now () + endDelay) { [weak self] in
            guard let self = self, !self.isPlayerTurn else { return }
            self.endTurn ()
        }
    }

    // MARK: - AI Card Play

    /// Plays cards from the AI's hand in descending priority order until it
    /// can no longer afford any remaining cards.
    ///
    /// The hand is re-sorted inside the loop on each iteration because playing
    /// a card changes both the hand contents and available mana, potentially
    /// making previously unaffordable cards playable or altering the optimal
    /// play order. A `played` flag drives the loop — it continues as long as
    /// at least one card was played in the previous pass.
    func aiPlayOptimalCards () {
        let sortedHand = opponent.hand.indices.sorted { a, b in
            aiCardPriority (opponent.hand [a]) > aiCardPriority (opponent.hand [b])
        }

        var played = true
        while played {
            played = false
            let affordable = sortedHand.filter { i in
                i < opponent.hand.count && opponent.mana >= opponent.effectiveManaCost (opponent.hand [i])
            }
            guard affordable.first (where: { opponent.mana >= opponent.effectiveManaCost (opponent.hand [$0]) }) != nil else { break }

            // Re-sort remaining hand each iteration to account for mana changes
            // and hand modifications from the previous play.
            let rebuildSorted = opponent.hand.indices
                .filter { opponent.mana >= opponent.effectiveManaCost (opponent.hand [$0]) }
                .sorted { a, b in aiCardPriority (opponent.hand [a]) > aiCardPriority (opponent.hand [b]) }
            guard let idx = rebuildSorted.first else { break }

            aiPlayCard (at: idx)
            played = true
            checkWinCondition ()
            if gameResult != .ongoing { return }
        }
    }

    /// Assigns a numeric priority score to a card from the AI's perspective,
    /// used by `aiPlayOptimalCards()` to sort the hand before each play.
    ///
    /// The scoring system evaluates each card based on the current board state
    /// rather than static card power alone. For example:
    /// - Curse of Circe scores -10 if the player has no creatures (no valid target)
    ///   but 90 if there are creatures to transform.
    /// - Poseidon's Tide and Zeus score higher when they can kill creatures outright.
    /// - Lightning Bolt scores highest when it can kill a threatening player creature.
    /// - Cards not explicitly scored fall back to a stat-efficiency formula
    ///   `(attack + health - manaCost) * 5 + 30`, rewarding efficient bodies.
    ///
    /// This produces an AI that makes contextually sensible decisions without
    /// requiring a full game-tree search.
    func aiCardPriority (_ card: Card) -> Int {
        var score = 0

        switch card.name {
        case "Curse of Circe":
            score = player.board.isEmpty ? -10 : 90          // Useless with no targets; excellent otherwise.
        case "Poseidon's Tide":
            let kills = player.board.filter { ($0.currentHealth ?? 0) <= 2 }.count
            score = 60 + kills * 15                           // Base value + bonus per creature killed.
        case "Zeus":
            let zeusKills = player.board.filter { ($0.currentHealth ?? 0) <= 2 }.count
            score = 70 + zeusKills * 20
        case "Lightning Bolt":
            if player.board.contains (where: { ($0.currentHealth ?? 0) <= 3 }) { score = 85 }  // Can kill a creature.
            else if player.health <= 15 { score = 40 }                                          // Pressure the hero.
            else { score = 30 }
        case "Sisyphus's Burden":
            let threat = player.board.max (by: { ($0.currentAttack ?? 0) < ($1.currentAttack ?? 0) })
            score = player.board.isEmpty ? -10 : 50 + (threat?.currentAttack ?? 0) * 5         // Higher for bigger threats.
        case "Shield of Sparta":
            score = opponent.board.isEmpty ? 5 : 45
        case "Prometheus's Fire":
            score = opponent.board.isEmpty ? 5 : 50
        case "Necromancy":
            let best = opponent.discard.filter { $0.type != .spell }.max (by: { ($0.attack ?? 0) < ($1.attack ?? 0) })
            score = best != nil ? 65 : -10                   // Only valuable if discard has creatures.
        case "Oracle's Vision":
            score = opponent.hand.count <= 2 ? 55 : 30       // More urgent when the hand is running dry.
        case "Olympian Blessing":
            score = opponent.health <= 20 ? 70 : 20          // More urgent when low on health.
        case "Trojan Horse":
            score = opponent.board.count < 2 ? 50 : 25       // More valuable when the board is thin.
        case "Ares":
            score = opponent.board.count >= 2 ? 80 : 55      // Much stronger with multiple creatures to buff.
        case "Hades":
            score = 75
        case "Poseidon":
            score = 70
        case "Athena":
            score = 72
        case "Heracles":
            let validTarget = player.board.contains (where: { ($0.currentHealth ?? 0) <= 2 })
            score = validTarget ? 78 : 20
        case "Achilles":
            score = 68
        default:
            // Stat efficiency formula for cards not individually tuned.
            let statValue = (card.attack ?? 0) + (card.health ?? 0) - card.manaCost
            score = 30 + statValue * 5
        }

        return score
    }

    // MARK: - AI Attack Execution

    /// Picks and executes a single attack for the best available AI creature.
    ///
    /// Attack resolution priority:
    /// 1. If the AI can deal lethal damage to the player hero this turn
    ///    (all attackers combined), attack the hero immediately.
    /// 2. Otherwise, if the player has creatures, find the most favourable
    ///    trade using `aiChooseBestTarget`.
    /// 3. If the player's board is empty, attack the hero directly.
    func aiExecuteNextAttack () {
        guard !isPlayerTurn else { return }

        let attackable = opponent.board.indices.filter { opponent.board [$0].canAttack }
        guard let atkIdx = aiChooseBestAttacker (from: attackable) else { return }

        // Lethal check: always prioritise ending the game if possible.
        if aiCanGoLethal (attackerIdx: atkIdx) {
            aiAttackHero (attackerIdx: atkIdx)
            return
        }

        if !player.board.isEmpty {
            if let defIdx = aiChooseBestTarget (attackerIdx: atkIdx) {
                aiAttackCreature (attackerIdx: atkIdx, defenderIdx: defIdx)
            } else {
                // No clearly good target found — attack index 0 as a fallback.
                aiAttackCreature (attackerIdx: atkIdx, defenderIdx: 0)
            }
        } else {
            aiAttackHero (attackerIdx: atkIdx)
        }
    }

    /// Selects the best attacker from the AI's ready creatures.
    ///
    /// Prefers a creature that can kill a player creature without dying in the
    /// trade (attack ≥ enemy health AND own health > enemy attack). If no such
    /// favourable trade exists, falls back to the first available attacker.
    func aiChooseBestAttacker (from attackable: [Int]) -> Int? {
        guard !attackable.isEmpty else { return nil }

        for i in attackable {
            let atk  = opponent.board [i].currentAttack  ?? 0
            for j in player.board.indices {
                let defHp  = player.board [j].currentHealth ?? 0
                let defAtk = player.board [j].currentAttack ?? 0
                let myHp   = opponent.board [i].currentHealth ?? 0
                // Favour trades where the AI creature kills but survives.
                if atk >= defHp && defAtk < myHp { return i }
            }
        }

        return attackable.first   // No ideal trade found — just pick any ready attacker.
    }

    /// Selects the best target on the player's board for the given AI attacker.
    ///
    /// The scoring formula evaluates four trade outcomes in descending value:
    /// 1. **Kill and survive** (score 100 + target attack): ideal trade.
    /// 2. **Kill but die** (score 40 + target attack): acceptable if the target is threatening.
    /// 3. **Survive but don't kill** (score 20): chip damage, low priority.
    /// 4. **Die without killing** (score -20 + target health): only if no better option.
    ///
    /// Minotaur taunt is applied first — if the player has a Minotaur, the AI
    /// is forced to target it before considering other creatures.
    ///
    /// Named card modifiers applied to the score:
    /// - **Medusa**: -200 — the AI will never willingly attack Medusa.
    /// - **Zeus, Ares, Poseidon**: bonuses for eliminating high-value targets.
    func aiChooseBestTarget (attackerIdx: Int) -> Int? {
        guard attackerIdx < opponent.board.count else { return nil }
        let atk  = opponent.board [attackerIdx].currentAttack  ?? 0
        let myHp = opponent.board [attackerIdx].currentHealth ?? 0

        // Minotaur taunt forces the AI to target it.
        if player.board.contains (where: { $0.name == "Minotaur" }) {
            return player.board.firstIndex (where: { $0.name == "Minotaur" })
        }

        var bestScore = Int.min
        var bestIdx: Int? = nil

        for j in player.board.indices {
            let defHp  = player.board [j].currentHealth ?? 0
            let defAtk = player.board [j].currentAttack ?? 0
            var score  = 0

            let kills    = atk >= defHp
            let survives = myHp > defAtk

            if kills && survives   { score = 100 + defAtk * 10 }   // Best: kill and live.
            else if kills          { score = 40  + defAtk * 5  }   // Trade: kill but die.
            else if survives       { score = 20                 }   // Chip: survive but don't kill.
            else                   { score = -20 + defHp       }   // Worst: die without killing.

            // Named card score adjustments.
            if player.board [j].name == "Medusa"   { score -= 200 }   // Never attack Medusa voluntarily.
            if player.board [j].name == "Zeus"      { score += 30  }   // Prioritise eliminating Zeus.
            if player.board [j].name == "Ares"      { score += 25  }   // Prioritise eliminating Ares.
            if player.board [j].name == "Poseidon"  { score += 20  }

            if score > bestScore { bestScore = score; bestIdx = j }
        }

        return bestIdx
    }

    /// Returns `true` if the combined attack power of all the AI's ready creatures
    /// is enough to reduce the player's health to 0 or below — i.e. the AI can
    /// win the game this turn if it attacks the hero with everything.
    ///
    /// Only valid when the player's board is empty (direct attacks are illegal
    /// otherwise), which is enforced by the guard in `aiExecuteNextAttack`.
    func aiCanGoLethal (attackerIdx: Int) -> Bool {
        guard attackerIdx < opponent.board.count else { return false }
        guard player.board.isEmpty else { return false }
        let totalDamage = opponent.board.filter { $0.canAttack }.reduce (0) { $0 + ($1.currentAttack ?? 0) }
        return totalDamage >= player.health
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
            opponent.board.append (played)
            log ("Opponent played \(card.name).")
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
            for i in player.board.indices { player.board [i].currentHealth = (player.board [i].currentHealth ?? 0) - 2 }
            removeDeadPlayerCreatures ()

        case "Ares":
            for i in opponent.board.indices where opponent.board [i].name != "Ares" {
                opponent.board [i].currentAttack = (opponent.board [i].currentAttack ?? 0) + 1
            }

        case "Heracles":
            // AI Heracles automatically targets the first player creature with ≤ 2 health.
            if let t = player.board.firstIndex (where: { ($0.currentHealth ?? 0) <= 2 }) {
                let name = player.board [t].name
                player.discard.append (player.board [t])
                player.board.remove (at: t)
                log ("Opponent's Heracles destroys \(name)!")
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
            // Prefer to kill; otherwise deal damage to the biggest threat; last resort: face.
            let killTarget = player.board.indices.filter { ($0 < player.board.count) && (player.board [$0].currentHealth ?? 0) <= 3 }
                .max (by: { (player.board [$0].currentAttack ?? 0) < (player.board [$1].currentAttack ?? 0) })
            if let t = killTarget {
                let name = player.board [t].name
                player.board [t].currentHealth = (player.board [t].currentHealth ?? 0) - 3
                log ("Opponent's Lightning Bolt kills \(name)!")
                removeDeadPlayerCreatures ()
            } else if !player.board.isEmpty {
                let t = player.board.indices.max (by: { (player.board [$0].currentAttack ?? 0) < (player.board [$1].currentAttack ?? 0) }) ?? 0
                player.board [t].currentHealth = (player.board [t].currentHealth ?? 0) - 3
                log ("Opponent's Lightning Bolt hits \(player.board [t].name) for 3!")
                removeDeadPlayerCreatures ()
            } else {
                player.health -= 3
                log ("Opponent's Lightning Bolt hits you for 3!")
            }

        case "Poseidon's Tide":
            for i in player.board.indices { player.board [i].currentHealth = (player.board [i].currentHealth ?? 0) - 2 }
            log ("Opponent's Poseidon's Tide deals 2 to all your creatures!")
            removeDeadPlayerCreatures ()

        case "Oracle's Vision":
            opponent.drawCard (); opponent.drawCard ()
            log ("Opponent uses Oracle's Vision to draw 2 cards.")

        case "Olympian Blessing":
            opponent.health = min (opponent.health + 5, 30)
            log ("Opponent heals 5 with Olympian Blessing!")

        case "Trojan Horse":
            for _ in 0..<3 {
                var s = Card (name: "Soldier", type: .monster, manaCost: 1, imageName: "soldier", description: "A 1/1 Trojan soldier.", attack: 1, health: 1)
                s.canAttack = false
                if opponent.hasAres () { s.currentAttack = (s.currentAttack ?? 0) + 1 }
                opponent.board.append (s)
            }
            log ("Opponent plays Trojan Horse — three soldiers appear!")

        case "Shield of Sparta":
            // Buff the AI's highest-attack creature for maximum offensive retention.
            if let i = opponent.board.indices.max (by: { (opponent.board [$0].currentAttack ?? 0) < (opponent.board [$1].currentAttack ?? 0) }) {
                opponent.board [i].currentHealth = (opponent.board [i].currentHealth ?? 0) + 3
                opponent.board [i].health = (opponent.board [i].health ?? 0) + 3
                log ("Opponent's Shield of Sparta buffs \(opponent.board [i].name) with +3 health!")
            }

        case "Prometheus's Fire":
            if let i = opponent.board.indices.max (by: { (opponent.board [$0].currentAttack ?? 0) < (opponent.board [$1].currentAttack ?? 0) }) {
                opponent.board [i].currentAttack = (opponent.board [i].currentAttack ?? 0) + 2
                log ("Opponent's Prometheus's Fire gives \(opponent.board [i].name) +2 attack!")
            }

        case "Curse of Circe":
            // Transform the highest combined-stat player creature into a 1/1 pig.
            if !player.board.isEmpty {
                let t = player.board.indices.max (by: {
                    ((player.board [$0].currentAttack ?? 0) + (player.board [$0].currentHealth ?? 0)) <
                    ((player.board [$1].currentAttack ?? 0) + (player.board [$1].currentHealth ?? 0))
                }) ?? 0
                let name = player.board [t].name
                var pig = Card (name: "Pig", type: .monster, manaCost: 1, imageName: "pig", description: "A transformed 1/1 pig.", attack: 1, health: 1)
                pig.canAttack = player.board [t].canAttack   // Preserve the transformed creature's readiness.
                player.board [t] = pig
                log ("Opponent's Curse of Circe transforms your \(name) into a pig!")
            }

        case "Sisyphus's Burden":
            // Silence the highest-attack player creature.
            if !player.board.isEmpty {
                let t = player.board.indices.max (by: { (player.board [$0].currentAttack ?? 0) < (player.board [$1].currentAttack ?? 0) }) ?? 0
                player.board [t].canAttack = false
                log ("Opponent's Sisyphus's Burden stops \(player.board [t].name) from attacking!")
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
                if opponent.hasAres () { revived.currentAttack = (revived.currentAttack ?? 0) + 1 }
                opponent.board.append (revived)
                log ("Opponent's Necromancy revives \(revived.name)!")
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

        if atkName == "Achilles" { atkDmg *= 2 }
        if defName == "Achilles" { defDmg *= 2 }

        if leonidasProtects (index: defenderIdx, on: player.board)   { atkDmg = max (1, atkDmg / 2) }
        if leonidasProtects (index: attackerIdx, on: opponent.board) { defDmg = max (1, defDmg / 2) }

        // Medusa destroys any creature that attacks her.
        if defName == "Medusa" {
            opponent.board [attackerIdx].currentHealth = -1
            opponent.board [attackerIdx].canAttack = false
            player.board [defenderIdx].currentHealth = max (-1, (player.board [defenderIdx].currentHealth ?? 0) - atkDmg)
            log ("Opponent's \(atkName) attacks Medusa and is destroyed!")
            removeDeadOpponentCreatures ()
            removeDeadPlayerCreatures ()
            checkWinCondition ()
            return
        }

        // Athena Divine Shield: absorb first hit at full health.
        if defName == "Athena" {
            let athenaCurrent = player.board [defenderIdx].currentHealth ?? 0
            let athenaBase    = player.board [defenderIdx].health ?? 0
            if athenaCurrent == athenaBase {
                player.board [defenderIdx].health = athenaBase - 1
                opponent.board [attackerIdx].currentHealth = max (-1, (opponent.board [attackerIdx].currentHealth ?? 0) - defDmg)
                opponent.board [attackerIdx].canAttack = false
                log ("Opponent hits your Athena's Divine Shield!")
                removeDeadOpponentCreatures ()
                checkWinCondition ()
                return
            }
        }

        // Standard simultaneous combat.
        player.board [defenderIdx].currentHealth   = max (-1, (player.board [defenderIdx].currentHealth ?? 0) - atkDmg)
        opponent.board [attackerIdx].currentHealth = max (-1, (opponent.board [attackerIdx].currentHealth ?? 0) - defDmg)
        opponent.board [attackerIdx].canAttack = false

        log ("Opponent's \(atkName) attacks your \(defName)!")
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
        let dmg  = opponent.board [attackerIdx].currentAttack ?? 0
        let name = opponent.board [attackerIdx].name
        player.health -= dmg
        opponent.board [attackerIdx].canAttack = false
        log ("Opponent's \(name) attacks you for \(dmg) damage!")
        checkWinCondition ()
    }

    /// Convenience wrapper that forwards to `Player.effectiveManaCost(_:)` for
    /// a given player instance. Kept for call sites that have a `Player` reference
    /// and want to go through `GameState` for consistency.
    func effectiveManaCost (_ card: Card, for p: Player) -> Int {
        return p.effectiveManaCost (card)
    }
}
