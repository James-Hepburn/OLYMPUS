import Foundation

// MARK: - CardType
/// Enumerates the four distinct card classifications in OLYMPUS.
///
/// `CardType` is the single source of truth for a card's visual identity and
/// role in gameplay. Every piece of type-dependent UI — border colours, filter
/// tabs, placeholder icons — derives from this enum, ensuring that adding a new
/// card type in the future requires changes in only one place.
///
/// Conforms to `Codable` so that `Card` values (which embed a `CardType`) can
/// be serialised to JSON for Firebase multiplayer sync and local persistence.
/// Conforms to `RawRepresentable` (via `String`) so the encoded value is a
/// human-readable string rather than an opaque integer.
enum CardType: String, Codable {
    case god, hero, monster, spell

    // MARK: Display

    /// A capitalised, human-readable name for the type, used in the card's
    /// type-badge label and the `AllCardsView` filter bar.
    var label: String {
        switch self {
        case .god:     return "God"
        case .hero:    return "Hero"
        case .monster: return "Monster"
        case .spell:   return "Spell"
        }
    }

    // MARK: Visual Identity

    /// A pair of hex colour strings that define the card's border gradient,
    /// running from the primary colour (index 0) to the secondary colour (index 1).
    ///
    /// Using two colours per type allows `LinearGradient` to give each category
    /// a distinctive shimmering border without needing separate asset catalogue
    /// entries. The primary colour (index 0) is also reused standalone for type
    /// badges, filter tabs, and stat text throughout the UI.
    ///
    /// - Gold   (`FFD700` → `FFA500`) — Gods: connotes divinity and rarity.
    /// - Silver (`C0C0C0` → `808080`) — Heroes: reflects their mortal-but-mighty status.
    /// - Bronze (`CD7F32` → `8B4513`) — Monsters: earthy tones signal danger and wildness.
    /// - Purple (`9B59B6` → `6C3483`) — Spells: arcane violet is a classic magic signifier.
    var borderColors: [String] {
        switch self {
        case .god:     return ["FFD700", "FFA500"]
        case .hero:    return ["C0C0C0", "808080"]
        case .monster: return ["CD7F32", "8B4513"]
        case .spell:   return ["9B59B6", "6C3483"]
        }
    }
}

// MARK: - Card
/// The core data model for a single card in OLYMPUS.
///
/// A `Card` is immutable at the collection level (name, type, costs, description)
/// but carries mutable in-game state (`currentAttack`, `currentHealth`, `canAttack`)
/// so that buffs, debuffs, and summoning-sickness tracking can be applied during
/// a match without creating separate wrapper types.
///
/// Conforms to `Identifiable` so SwiftUI `ForEach` loops can diff card lists
/// efficiently. Conforms to `Codable` for Firebase real-time database sync,
/// allowing the full game state — including mid-combat stat changes — to be
/// serialised and broadcast to the opponent each turn.
struct Card: Identifiable, Codable {

    // MARK: Identity

    /// A UUID string assigned at initialisation time. Unique per card *instance*
    /// rather than per card *definition*, so two copies of "Zeus" in the same deck
    /// are distinguishable by the game engine and by SwiftUI's diffing algorithm.
    var id: String

    // MARK: Static Properties
    // These values come from the card definition and never change during a match.

    /// The display name of the card (e.g. "Zeus", "Lightning Bolt").
    let name: String

    /// The card's classification, which governs its border colours, grid filtering,
    /// and whether combat stats are shown in the UI.
    let type: CardType

    /// The amount of mana required to play this card. Mana increases by one each
    /// turn (capped at 10), so higher-cost cards represent a strategic investment
    /// in waiting for the right moment.
    let manaCost: Int

    /// The name of the image asset in the asset catalogue used for card artwork.
    /// When no matching asset is found, `CardView` falls back to a type-appropriate
    /// SF Symbol placeholder so the layout never breaks during development.
    let imageName: String

    /// A one-sentence description of the card's passive, triggered, or on-play ability.
    /// Spell cards use this exclusively (they have no attack/health stats).
    let description: String

    // MARK: Base Combat Stats
    // Optional because spell cards have no board presence and therefore no combat stats.

    /// The base attack value from the card definition. Stored separately from
    /// `currentAttack` so that temporary buffs (e.g. Prometheus's Fire) can be
    /// reversed at end-of-turn without losing the original value.
    var attack: Int?

    /// The base health value from the card definition. Stored separately from
    /// `currentHealth` for the same reason as `attack`.
    var health: Int?

    // MARK: In-Game State
    // Mutable values that reflect the card's current condition on the board.

    /// The card's attack power as it stands right now, accounting for any buffs
    /// or debuffs applied this match. Initialised to `attack` when the card is created.
    var currentAttack: Int?

    /// The card's remaining health on the board. Decremented when the card takes
    /// damage; the card is destroyed and removed from the board when this reaches 0.
    var currentHealth: Int?

    /// Tracks whether this creature is eligible to attack this turn.
    /// Set to `false` when a card is first played (summoning sickness) and flipped
    /// to `true` at the start of the owning player's next turn. Also reset to `false`
    /// after the card has attacked once, enforcing the one-attack-per-turn rule.
    var canAttack: Bool = false

    // MARK: Initialiser

    /// Creates a new `Card` instance with a freshly generated UUID.
    ///
    /// `currentAttack` and `currentHealth` are seeded from `attack` and `health`
    /// so that in-game mutations always have valid starting values without requiring
    /// the caller to pass redundant arguments.
    init (name: String, type: CardType, manaCost: Int, imageName: String, description: String, attack: Int? = nil, health: Int? = nil) {
        self.id = UUID ().uuidString
        self.name = name
        self.type = type
        self.manaCost = manaCost
        self.imageName = imageName
        self.description = description
        self.attack = attack
        self.health = health
        self.currentAttack = attack
        self.currentHealth = health
    }
}

// MARK: - Card Collection
extension Card {

    /// The complete, canonical set of 30 cards available in OLYMPUS.
    ///
    /// Both players draw from this shared pool, so balance is purely a function
    /// of card design rather than deck-building. The distribution is:
    /// - **6 Gods** — High mana cost (5–8), powerful passive or triggered abilities.
    /// - **6 Heroes** — Mid-range cost (3–4), strong individual effects.
    /// - **6 Monsters** — Low-to-mid cost (1–4), efficient bodies with situational abilities.
    /// - **10 Spells** — Instant effects with no board presence; range from removal to healing.
    ///
    /// Defined as a static constant so the collection is allocated once and shared
    /// across all call sites (card library view, deck shuffling, game state init).
    static let allCards: [Card] = [

        // MARK: Gods (6 cards)
        // The rarest tier. High mana investment is offset by board-wide or
        // persistent effects that can swing the game when played at the right moment.
        Card (name: "Zeus",     type: .god,     manaCost: 5, imageName: "zeus",     description: "When played, deal 2 damage to all enemy creatures.", attack: 4, health: 6),
        Card (name: "Poseidon", type: .god,     manaCost: 6, imageName: "poseidon", description: "Your creatures can't be targeted by spells.",          attack: 3, health: 8),
        Card (name: "Ares",     type: .god,     manaCost: 7, imageName: "ares",     description: "All your creatures gain +1 attack.",                   attack: 6, health: 5),
        Card (name: "Athena",   type: .god,     manaCost: 5, imageName: "athena",   description: "Divine Shield: ignores the first damage taken.",        attack: 3, health: 7),
        Card (name: "Hades",    type: .god,     manaCost: 8, imageName: "hades",    description: "When an enemy creature dies, gain 2 health.",           attack: 5, health: 5),
        Card (name: "Apollo",   type: .god,     manaCost: 6, imageName: "apollo",   description: "At the start of your turn, heal your hero for 2.",      attack: 2, health: 6),

        // MARK: Heroes (6 cards)
        // Mid-game power plays. Each hero has a unique ability that rewards
        // strategic timing — whether that's immediate removal, card advantage, or aggression.
        Card (name: "Achilles", type: .hero,    manaCost: 4, imageName: "achilles", description: "Deals double damage but takes double damage.",          attack: 5, health: 3),
        Card (name: "Odysseus", type: .hero,    manaCost: 3, imageName: "odysseus", description: "When played, look at the top 2 cards and pick one.",    attack: 2, health: 4),
        Card (name: "Heracles", type: .hero,    manaCost: 4, imageName: "heracles", description: "Destroy one enemy creature with 2 or less health.",     attack: 4, health: 4),
        Card (name: "Perseus",  type: .hero,    manaCost: 3, imageName: "perseus",  description: "Can attack immediately the turn he's played.",          attack: 3, health: 3),
        Card (name: "Leonidas", type: .hero,    manaCost: 4, imageName: "leonidas", description: "Adjacent creatures take half damage.",                  attack: 2, health: 6),
        Card (name: "Medea",    type: .hero,    manaCost: 3, imageName: "medea",    description: "Spells you cast cost 1 less mana.",                     attack: 2, health: 3),

        // MARK: Monsters (6 cards)
        // Efficient early-to-mid game threats. Several have mechanics that
        // punish opponents for ignoring them (Minotaur taunt, Medusa retaliation).
        Card (name: "Minotaur", type: .monster, manaCost: 3, imageName: "minotaur", description: "Must be attacked before heroes or gods.",              attack: 3, health: 4),
        Card (name: "Cerberus", type: .monster, manaCost: 4, imageName: "cerberus", description: "Summons 3 separate 2/2 creatures instead of one.",     attack: 2, health: 2),
        Card (name: "Medusa",   type: .monster, manaCost: 3, imageName: "medusa",   description: "Any creature that attacks her is destroyed.",           attack: 1, health: 4),
        Card (name: "Hydra",    type: .monster, manaCost: 4, imageName: "hydra",    description: "When destroyed, summons two 2/1 Hydra Heads.",          attack: 4, health: 3),
        Card (name: "Cyclops",  type: .monster, manaCost: 2, imageName: "cyclops",  description: "A powerful brute with no special ability.",             attack: 3, health: 2),
        Card (name: "Harpy",    type: .monster, manaCost: 1, imageName: "harpy",    description: "Fast and cheap, good for early turns.",                 attack: 1, health: 2),

        // MARK: Spells (10 cards)
        // Instant-speed effects with no board presence. The largest category by
        // count, providing answers for nearly every board state: targeted removal,
        // area damage, healing, card draw, buffs, debuffs, and reanimation.
        Card (name: "Lightning Bolt",      type: .spell, manaCost: 2, imageName: "spell_bolt",       description: "Deal 3 damage to any target."),
        Card (name: "Poseidon's Tide",     type: .spell, manaCost: 3, imageName: "spell_tide",       description: "Deal 2 damage to all enemy creatures."),
        Card (name: "Trojan Horse",        type: .spell, manaCost: 4, imageName: "spell_trojan",     description: "Summon three 1/1 soldiers onto your board."),
        Card (name: "Oracle's Vision",     type: .spell, manaCost: 1, imageName: "spell_oracle",     description: "Draw 2 cards."),
        Card (name: "Prometheus's Fire",   type: .spell, manaCost: 2, imageName: "spell_fire",       description: "Give a creature +2 attack until end of turn."),
        Card (name: "Shield of Sparta",    type: .spell, manaCost: 2, imageName: "spell_shield",     description: "Give a creature +3 health."),
        Card (name: "Curse of Circe",      type: .spell, manaCost: 3, imageName: "spell_circe",      description: "Transform an enemy creature into a 1/1 pig."),
        Card (name: "Sisyphus's Burden",   type: .spell, manaCost: 2, imageName: "spell_sisyphus",   description: "An enemy creature can't attack next turn."),
        Card (name: "Necromancy",          type: .spell, manaCost: 5, imageName: "spell_necromancy", description: "Bring back any creature from your discard pile."),
        Card (name: "Olympian Blessing",   type: .spell, manaCost: 3, imageName: "spell_blessing",   description: "Heal your hero for 5."),
    ]
}
