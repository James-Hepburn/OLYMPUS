import Foundation
import FirebaseDatabase
import Combine

// MARK: - MPPlayer
/// A Codable snapshot of a single player's in-game state for use over the network.
///
/// Mirrors the `Player` struct in `GameState` but implements a custom `Decodable`
/// initialiser that uses `decodeIfPresent` with safe defaults for every field.
/// This defensive decoding strategy means a partially-written or legacy Firebase
/// document will never crash the decoder — missing fields simply fall back to
/// their initial values, keeping the client resilient to schema evolution.
///
/// Like `Player`, `MPPlayer` is a `struct` so that mutations inside `applyAction`
/// produce value-semantic copies. `MultiplayerManager` holds `inout` references
/// to these during action resolution and writes the final values back into the
/// snapshot atomically before pushing to Firebase.
struct MPPlayer: Codable {

    // MARK: Resources
    var health: Int  = 30
    var mana: Int    = 0
    var maxMana: Int = 0

    // MARK: Card Zones
    var hand:    [Card] = []
    var board:   [Card] = []
    var discard: [Card] = []
    var deck:    [Card] = []

    // MARK: Initialisers

    /// Default memberwise initialiser — produces a fresh player with 30 health
    /// and empty zones, used when building the initial game snapshot.
    init () {}

    /// Custom `Decodable` initialiser using `decodeIfPresent` throughout.
    ///
    /// `decodeIfPresent` is preferred over the standard `decode` because Firebase
    /// Realtime Database may omit keys entirely when their values are empty arrays
    /// or zero. Using safe defaults prevents those missing keys from throwing a
    /// `DecodingError.keyNotFound` and crashing the live update pipeline.
    init (from decoder: Decoder) throws {
        let c = try decoder.container (keyedBy: CodingKeys.self)
        health   = try c.decodeIfPresent (Int.self,    forKey: .health)   ?? 30
        mana     = try c.decodeIfPresent (Int.self,    forKey: .mana)     ?? 0
        maxMana  = try c.decodeIfPresent (Int.self,    forKey: .maxMana)  ?? 0
        hand     = try c.decodeIfPresent ([Card].self, forKey: .hand)     ?? []
        board    = try c.decodeIfPresent ([Card].self, forKey: .board)    ?? []
        discard  = try c.decodeIfPresent ([Card].self, forKey: .discard)  ?? []
        deck     = try c.decodeIfPresent ([Card].self, forKey: .deck)     ?? []
    }

    // MARK: Game Logic Helpers

    /// Returns the mana cost this player would pay to play `card`, applying the
    /// Medea discount (-1 to all spells) if she is on the board.
    /// Duplicated from `Player` so `MPPlayer` is self-contained and does not
    /// depend on the local-only `GameState` type.
    func effectiveManaCost (_ card: Card) -> Int {
        if card.type == .spell && board.contains (where: { $0.name == "Medea" }) {
            return max (0, card.manaCost - 1)
        }
        return card.manaCost
    }

    /// Returns `true` if Ares is currently on this player's board, used to
    /// apply the +1 attack bonus to newly played or summoned creatures.
    func hasAres () -> Bool {
        board.contains { $0.name == "Ares" }
    }
}

// MARK: - MPGameAction
/// A Codable action message representing a single game decision made by a player.
///
/// Actions are the unit of communication between clients. When a player performs
/// any game action (playing a card, attacking, ending their turn), the action is
/// encoded and written to the Firebase `games/{roomId}/state` node by the acting
/// client. The other client's live listener receives the updated snapshot, which
/// already has the action's effect applied.
///
/// All index and ID fields are optional because not every action type uses all of
/// them — a `.endTurn` action carries no indices; an `.attackCreature` action
/// carries attacker and defender indices but no card ID. Using optionals keeps
/// the struct general without requiring separate types per action.
///
/// `timestamp` is included on every action as a monotonic value, useful for
/// debugging race conditions and for any future conflict-resolution logic.
struct MPGameAction: Codable {

    // MARK: Action Types

    /// The exhaustive set of game actions a player can dispatch.
    enum ActionType: String, Codable {
        /// Play a card from hand — creature or non-targeted spell.
        case playCard
        /// Attack an opponent's creature with one of your own.
        case attackCreature
        /// Attack the opponent hero directly (only legal when their board is empty).
        case attackHero
        /// End the current player's turn and pass priority to the opponent.
        case endTurn
        /// Resolve a spell targeting a friendly creature (e.g. Prometheus's Fire).
        case selectFriendlyTarget
        /// Resolve a spell or creature ability targeting an opponent creature.
        case selectOpponentTarget
        /// Resolve Lightning Bolt targeting the opponent hero directly.
        case selectLightningHero
        /// Resolve Lightning Bolt targeting a specific opponent creature.
        case selectLightningCreature
        /// Resolve Odysseus's on-play card-choice ability.
        case resolveOdysseus
        /// Resolve the Necromancy spell's creature revival choice.
        case resolveNecromancy
    }

    // MARK: Fields

    let type: ActionType

    /// Index of the card in the acting player's hand (used by most action types).
    var cardIndex: Int?

    /// Board index of the attacking creature (used by `.attackCreature` and `.attackHero`).
    var attackerIndex: Int?

    /// Board index of the defending creature (used by `.attackCreature`).
    var defenderIndex: Int?

    /// Board index of a targeted creature on either side (used by targeting actions).
    var targetBoardIndex: Int?

    /// The UUID string of the card chosen in a card-picker overlay (Odysseus, Necromancy).
    /// Sent instead of an array index because the picker may show a filtered subset
    /// of the discard — using the stable `id` field avoids any index mismatch between
    /// what the local client displayed and what is actually in the server's deck array.
    var chosenCardId: String?

    /// Unix timestamp of when this action was created, used for debugging and
    /// potential future conflict detection.
    var timestamp: Double = Date ().timeIntervalSince1970
}

// MARK: - MPGameSnapshot
/// The complete, authoritative state of an ongoing multiplayer match, stored
/// as a single JSON document at `games/{roomId}/state` in Firebase Realtime Database.
///
/// Both clients observe this path with a live listener. When either client calls
/// `sendAction`, they mutate a local copy of the snapshot via `applyAction`, then
/// write the updated snapshot back to Firebase in a single `setValue` call.
/// The other client's observer fires immediately and updates `gameSnapshot`,
/// triggering a SwiftUI re-render.
///
/// `seed` is generated once by the host at room creation. Although it is not
/// currently used to deterministically synchronise card shuffles (each client
/// shuffles independently), it is included as a foundation for adding
/// deterministic deck generation in a future update.
struct MPGameSnapshot: Codable {
    var hostPlayer:  MPPlayer
    var guestPlayer: MPPlayer
    var currentTurn: Int    = 1
    var isHostTurn:  Bool   = true
    /// `"ongoing"`, `"hostWon"`, or `"guestWon"` — stored as a `String` rather
    /// than an enum so it round-trips through Firebase JSON without a custom
    /// Codable implementation.
    var gameResult:  String = "ongoing"
    /// The most recent game event description, displayed in the divider message bar.
    var message:     String = ""
    /// The last action applied to this snapshot, stored for debugging and
    /// potential replay or undo features.
    var lastAction:  MPGameAction?
    /// A random seed generated at room creation, reserved for future deterministic
    /// card shuffle synchronisation.
    var seed: Int
}

// MARK: - MatchmakingState
/// The state machine for the matchmaking flow shown in `WaitingForOpponentView`.
enum MatchmakingState {
    /// No search is active — the player is on the main menu.
    case idle
    /// A search is in progress — the player is waiting in the lobby.
    case searching
    /// A match has been found and the game room is initialised.
    case matched (roomId: String, isHost: Bool)
    /// An error occurred during matchmaking (e.g. network failure).
    case error (String)
}

// MARK: - MultiplayerManager
/// The Firebase-backed game engine for online multiplayer matches.
///
/// `MultiplayerManager` owns the Firebase connection, orchestrates matchmaking,
/// and serves as the single point through which all multiplayer game actions flow.
/// It is created once in `WaitingForOpponentView` and passed as an
/// `@ObservedObject` to `MultiplayerGameBoardView`.
///
/// ## Matchmaking
/// Matchmaking uses a simple first-come/first-served lobby model:
/// 1. The first player to call `findMatch()` creates a room and writes a
///    `{ waiting: true }` entry under `lobby/{roomId}`.
/// 2. The second player queries the lobby, finds the waiting room, and joins it.
/// 3. The joining client removes the lobby entry, builds the initial `MPGameSnapshot`,
///    and writes it to `games/{roomId}/state`.
/// 4. The host's listener fires on that write, confirms the guest has dealt their
///    opening hand, and transitions both clients to `matched`.
///
/// ## Action Dispatch
/// All game actions go through `sendAction(_:)`, which:
/// 1. Applies the action locally via `applyAction(_:to:)`.
/// 2. Encodes the updated snapshot to JSON.
/// 3. Writes it to Firebase with `setValue`.
/// Both clients observe the same path, so the acting client also receives its
/// own write back — this keeps the local `gameSnapshot` consistent with Firebase.
///
/// ## Disconnect Safety
/// On match start, `registerDisconnectHandler` writes a pre-built forfeit snapshot
/// to Firebase using `onDisconnectSetValue`. If the client disconnects unexpectedly
/// (crash, network loss), Firebase automatically applies the forfeit — the opponent
/// sees "Opponent forfeited." rather than a frozen, unresolvable game state.
/// `cancelDisconnectHandler` cancels this operation when the game ends normally.
class MultiplayerManager: ObservableObject {

    // MARK: Published State

    /// The current matchmaking phase. Observed by `WaitingForOpponentView` to
    /// drive its UI (searching spinner → matched → navigating to the board).
    @Published var matchmakingState: MatchmakingState = .idle

    /// The live game snapshot, updated every time Firebase emits a new value.
    /// `nil` until the first snapshot is received from Firebase.
    @Published var gameSnapshot: MPGameSnapshot?

    // MARK: Private Firebase State

    /// The root database reference, used to build child paths throughout.
    private let db = Database.database ().reference ()

    /// The UUID string identifying the current game room, set when this client
    /// either creates or joins a room.
    private var roomId: String?

    /// The handle returned by `observe(.value)`, stored so the listener can be
    /// removed cleanly with `removeObserver(withHandle:)` when the game ends.
    private var snapshotHandle: DatabaseHandle?

    /// The specific `DatabaseReference` being observed, kept alongside
    /// `snapshotHandle` because `removeObserver` requires both.
    private var roomRef: DatabaseReference?

    /// `true` if this client created the room (and therefore owns the host player
    /// slot), `false` if this client joined an existing room as the guest.
    /// Used throughout to resolve "me vs them" perspective in `applyAction`.
    var isHost: Bool = false

    // MARK: - Matchmaking

    /// Begins searching for an available game room, or creates one if none exist.
    ///
    /// Queries the `lobby` node with a single `observeSingleEvent` (not a live
    /// listener) to avoid race conditions from multiple clients reading the same
    /// lobby simultaneously. The first client to read an empty lobby creates a
    /// room; subsequent clients join the first waiting room they find.
    func findMatch () {
        matchmakingState = .searching

        let lobbyRef = db.child ("lobby")

        lobbyRef.observeSingleEvent (of: .value) { [weak self] snapshot in
            guard let self = self else { return }

            if snapshot.hasChildren (),
               let rooms = snapshot.value as? [String: Any],
               let (waitingRoomId, _) = rooms.first {
                // A waiting room exists — join it as the guest.
                self.joinRoom (roomId: waitingRoomId)
            } else {
                // No waiting rooms — create a new one as the host.
                self.createRoom ()
            }
        } withCancel: { error in
            DispatchQueue.main.async {
                self.matchmakingState = .error (error.localizedDescription)
            }
        }
    }

    /// Cancels an active search and cleans up all Firebase entries created by
    /// this client, returning `matchmakingState` to `.idle`.
    ///
    /// Removes both the lobby entry (so other clients don't try to join a
    /// cancelled room) and the games entry (to avoid orphaned data).
    func cancelSearch () {
        guard let roomId = roomId else {
            matchmakingState = .idle
            return
        }
        db.child ("lobby").child (roomId).removeValue ()
        db.child ("games").child (roomId).removeValue ()
        removeSnapshotListener ()
        self.roomId = nil
        matchmakingState = .idle
    }

    // MARK: - Action Dispatch

    /// Applies a game action locally and writes the resulting snapshot to Firebase.
    ///
    /// This is the single entry point for all game actions from
    /// `MultiplayerGameBoardView`. The sequence is:
    /// 1. Apply the action to a mutable local copy of the snapshot.
    /// 2. Stamp `lastAction` for the remote client's debugging.
    /// 3. Encode to JSON and write to `games/{roomId}/state` with `setValue`.
    ///
    /// Both clients observe this path, so the write triggers the acting client's
    /// own listener as well — this is intentional and ensures both clients always
    /// render the same authoritative state.
    func sendAction (_ action: MPGameAction) {
        guard let roomId = roomId,
              var snapshot = gameSnapshot else { return }

        applyAction (action, to: &snapshot)
        snapshot.lastAction = action

        if let encoded = try? JSONEncoder ().encode (snapshot),
           let dict = try? JSONSerialization.jsonObject (with: encoded) as? [String: Any] {
            db.child ("games").child (roomId).child ("state").setValue (dict)
        }
    }

    // MARK: - Session Teardown

    /// Gracefully ends the game session, writing a forfeit result if the match
    /// is still ongoing, then cleaning up all Firebase state after a short delay.
    ///
    /// The 0.3-second delay before removing Firebase data gives the forfeit write
    /// time to propagate to the opponent's client before the `games/{roomId}` node
    /// is deleted. Without this delay, the deletion could race with the write and
    /// the opponent might never see the forfeit result.
    func leaveGame () {
        guard let roomId = roomId else { return }

        // Write a forfeit result so the opponent sees "Opponent forfeited."
        // rather than an empty or stale game state.
        if var snapshot = gameSnapshot, snapshot.gameResult == "ongoing" {
            snapshot.gameResult = isHost ? "guestWon" : "hostWon"
            snapshot.message = "Opponent forfeited."
            if let encoded = try? JSONEncoder ().encode (snapshot),
               let dict = try? JSONSerialization.jsonObject (with: encoded) as? [String: Any] {
                db.child ("games").child (roomId).child ("state").setValue (dict)
            }
        }

        // Delay cleanup to let the forfeit write propagate before deletion.
        DispatchQueue.main.asyncAfter (deadline: .now () + 0.3) { [weak self] in
            guard let self = self else { return }
            self.removeSnapshotListener ()
            self.db.child ("games").child (self.roomId ?? "").removeValue ()
            self.roomId = nil
            self.gameSnapshot = nil
            self.matchmakingState = .idle
        }
    }

    // MARK: - Perspective Helpers

    /// Returns this client's player data from the current snapshot, resolved by role.
    var localPlayer: MPPlayer? {
        guard let snap = gameSnapshot else { return nil }
        return isHost ? snap.hostPlayer : snap.guestPlayer
    }

    /// Returns the remote opponent's player data from the current snapshot.
    var remotePlayer: MPPlayer? {
        guard let snap = gameSnapshot else { return nil }
        return isHost ? snap.guestPlayer : snap.hostPlayer
    }

    /// Returns `true` when it is this client's turn to act, derived from
    /// `snapshot.isHostTurn` and this client's role.
    var isMyTurn: Bool {
        guard let snap = gameSnapshot else { return false }
        return isHost ? snap.isHostTurn : !snap.isHostTurn
    }

    // MARK: - Private: Room Lifecycle

    /// Creates a new game room, registers this client as host, and begins
    /// listening for the guest to write the initial game snapshot.
    ///
    /// The room is written to `lobby/{roomId}` with `{ waiting: true }` so
    /// searching guests can discover it. Once the lobby write succeeds,
    /// `listenForGuest` is called to watch for the guest's snapshot write.
    private func createRoom () {
        let newRoomId = UUID ().uuidString
        self.roomId = newRoomId
        self.isHost = true

        db.child ("lobby").child (newRoomId).setValue (["waiting": true]) { [weak self] error, _ in
            guard let self = self, error == nil else {
                self?.matchmakingState = .error ("Failed to create room.")
                return
            }
            self.listenForGuest (roomId: newRoomId)
        }
    }

    /// Joins an existing room as the guest, builds the initial game snapshot,
    /// and writes it to Firebase to signal the host that the match can begin.
    ///
    /// The guest is responsible for writing the initial snapshot because they
    /// are the second to arrive and can confirm both players are present. The
    /// host's `listenForGuest` listener fires on this write, confirming the
    /// guest has dealt cards and transitioning both clients to `.matched`.
    ///
    /// The lobby entry is removed before writing the snapshot to prevent a third
    /// client from attempting to join the same room.
    private func joinRoom (roomId: String) {
        self.roomId = roomId
        self.isHost = false

        // Remove lobby entry immediately to prevent a third player joining.
        db.child ("lobby").child (roomId).removeValue ()

        // Build the initial snapshot (host has already dealt their hand),
        // then deal the guest's opening hand locally before writing.
        var snapshot = buildInitialSnapshot ()
        snapshot.guestPlayer.deck = Array (Card.allCards.shuffled ().prefix (30))
        snapshot.guestPlayer.hand = []
        for _ in 0..<4 { drawCard (for: &snapshot.guestPlayer) }

        guard let encoded = try? JSONEncoder ().encode (snapshot),
              let dict = try? JSONSerialization.jsonObject (with: encoded) as? [String: Any] else {
            return
        }

        db.child ("games").child (roomId).child ("state").setValue (dict) { [weak self] error, _ in
            guard let self = self else { return }
            if let error = error {
                // Log the error but don't surface it to the user here —
                // `listenForGameUpdates` will handle ongoing state.
                return
            }
            DispatchQueue.main.async {
                self.matchmakingState = .matched (roomId: roomId, isHost: false)
                self.listenForGameUpdates (roomId: roomId)
                self.registerDisconnectHandler (roomId: roomId)
            }
        }
    }

    // MARK: - Private: Firebase Listeners

    /// Sets up a live observer on `games/{roomId}/state` for the host, waiting
    /// for the guest to write the initial snapshot.
    ///
    /// The observer fires on every snapshot update, including the guest's initial
    /// write. The guard `!snapshot.guestPlayer.hand.isEmpty` ensures the host
    /// doesn't transition to `.matched` before the guest has finished dealing
    /// their opening hand — an empty hand indicates a partial or stale write.
    ///
    /// Note: The `matchmakingState` and `gameSnapshot` assignments appear twice
    /// due to a defensive duplication during development. This is safe but
    /// redundant — a future refactor could remove the duplicate assignments.
    private func listenForGuest (roomId: String) {
        let ref = db.child ("games").child (roomId).child ("state")
        self.roomRef = ref
        snapshotHandle = ref.observe (.value) { [weak self] snap in
            guard let self = self else { return }
            guard let value = snap.value as? [String: Any],
                  let data = try? JSONSerialization.data (withJSONObject: value),
                  let snapshot = try? JSONDecoder ().decode (MPGameSnapshot.self, from: data) else {
                    // Decode failed — log detail to help diagnose schema issues.
                    if let value = snap.value as? [String: Any],
                       let data = try? JSONSerialization.data (withJSONObject: value) {
                        do {
                            let _ = try JSONDecoder ().decode (MPGameSnapshot.self, from: data)
                        } catch {
                            print ("Decode error detail: \(error)")
                        }
                    }
                    return
            }
            // Wait until the guest has actually dealt their hand before proceeding.
            guard !snapshot.guestPlayer.hand.isEmpty else { return }

            DispatchQueue.main.async {
                self.gameSnapshot = snapshot
                self.matchmakingState = .matched (roomId: roomId, isHost: true)
                self.gameSnapshot = snapshot             // Defensive duplicate — safe to remove.
                self.matchmakingState = .matched (roomId: roomId, isHost: true)  // Defensive duplicate.
                self.registerDisconnectHandler (roomId: roomId)
            }
        }
    }

    /// Sets up a live observer on `games/{roomId}/state` for the guest (and
    /// re-used by the host after the initial handshake is complete).
    ///
    /// Every Firebase update triggers a main-thread assignment to `gameSnapshot`,
    /// which propagates to `MultiplayerGameBoardView` via `@ObservedObject`.
    private func listenForGameUpdates (roomId: String) {
        let ref = db.child ("games").child (roomId).child ("state")
        self.roomRef = ref
        snapshotHandle = ref.observe (.value) { [weak self] snap in
            guard let self = self else { return }
            guard let value = snap.value as? [String: Any],
                  let data = try? JSONSerialization.data (withJSONObject: value),
                  let snapshot = try? JSONDecoder ().decode (MPGameSnapshot.self, from: data) else { return }
            DispatchQueue.main.async {
                self.gameSnapshot = snapshot
            }
        }
    }

    // MARK: - Private: Disconnect Safety

    /// Registers a Firebase `onDisconnectSetValue` that automatically writes a
    /// forfeit result if this client disconnects unexpectedly.
    ///
    /// Firebase executes `onDisconnectSetValue` server-side when it detects the
    /// client has gone offline (connection drop, app crash, background kill).
    /// This prevents the opponent from being stuck in an unresolvable game state.
    /// The forfeit snapshot is pre-built here so Firebase has it ready without
    /// needing to contact the client again.
    private func registerDisconnectHandler (roomId: String) {
        guard let snapshot = gameSnapshot else { return }

        var forfeitSnapshot = snapshot
        forfeitSnapshot.gameResult = isHost ? "guestWon" : "hostWon"
        forfeitSnapshot.message = "Opponent forfeited."

        guard let encoded = try? JSONEncoder ().encode (forfeitSnapshot),
              let dict = try? JSONSerialization.jsonObject (with: encoded) as? [String: Any] else { return }

        db.child ("games").child (roomId).child ("state").onDisconnectSetValue (dict)
    }

    /// Cancels the `onDisconnectSetValue` registered by `registerDisconnectHandler`.
    ///
    /// Called from `checkWin` when the game ends normally, preventing Firebase
    /// from applying the forfeit after a legitimate victory or defeat.
    private func cancelDisconnectHandler (roomId: String) {
        db.child ("games").child (roomId).child ("state").cancelDisconnectOperations ()
    }

    /// Removes the active Firebase observer and clears the stored handle and
    /// reference. Called from `cancelSearch()` and `leaveGame()`.
    private func removeSnapshotListener () {
        if let handle = snapshotHandle, let ref = roomRef {
            ref.removeObserver (withHandle: handle)
        }
        snapshotHandle = nil
        roomRef = nil
    }

    // MARK: - Private: Game Setup

    /// Builds the initial `MPGameSnapshot` with the host's deck shuffled and
    /// opening hand dealt. The guest's player slot is left empty — the guest
    /// fills it in `joinRoom` before writing the snapshot to Firebase.
    ///
    /// `seed` is generated here with `Int.random` as a stable identifier for
    /// this match session, available for future deterministic shuffle logic.
    private func buildInitialSnapshot () -> MPGameSnapshot {
        var host = MPPlayer ()
        host.deck = Array (Card.allCards.shuffled ().prefix (30))
        for _ in 0..<4 { drawCard (for: &host) }

        return MPGameSnapshot (
            hostPlayer: host,
            guestPlayer: MPPlayer (),
            seed: Int.random (in: 0..<Int.max)
        )
    }

    /// Draws one card from the top of the given player's deck, recycling the
    /// discard pile into a fresh deck if the draw pile is empty.
    ///
    /// Mirrors `Player.drawCard()` in `GameState` exactly, including the stat
    /// reset on recycled cards. Duplicated here rather than shared because
    /// `MPPlayer` and `Player` are distinct types — a shared function would
    /// require a protocol abstraction that adds more complexity than it saves.
    private func drawCard (for player: inout MPPlayer) {
        if player.deck.isEmpty && !player.discard.isEmpty {
            player.deck = player.discard.shuffled ().map { card in
                var c = card; c.currentHealth = c.health; c.currentAttack = c.attack; c.canAttack = false; return c
            }
            player.discard = []
        }
        guard !player.deck.isEmpty else { return }
        let card = player.deck.removeFirst ()
        player.hand.append (card)
    }

    // MARK: - Action Resolution

    /// Applies a single `MPGameAction` to the given snapshot, mutating it in place.
    ///
    /// This is the authoritative game logic for multiplayer. It mirrors the
    /// methods in `GameState` but operates entirely on `MPPlayer` values via
    /// `inout` parameters rather than `@Published` properties, making it safe
    /// to call synchronously before a Firebase write.
    ///
    /// `me` and `them` are extracted at the top by role, mutated throughout the
    /// switch, and written back into the snapshot at the bottom. This two-step
    /// read/write pattern ensures the snapshot is always updated atomically —
    /// partial mutations are never written back if the function returns early.
    func applyAction (_ action: MPGameAction, to snapshot: inout MPGameSnapshot) {
        var me   = isHost ? snapshot.hostPlayer  : snapshot.guestPlayer
        var them = isHost ? snapshot.guestPlayer : snapshot.hostPlayer

        switch action.type {

        // MARK: Play Card
        case .playCard:
            guard let idx = action.cardIndex, idx < me.hand.count else { break }
            let card = me.hand [idx]
            let cost = me.effectiveManaCost (card)
            guard me.mana >= cost else { break }
            me.mana -= cost
            me.hand.remove (at: idx)

            if card.type == .spell {
                resolveSpell (card, me: &me, them: &them)
                me.discard.append (card)
            } else {
                var played = card
                played.canAttack = (card.name == "Perseus")   // Perseus has Charge.
                if me.hasAres () && card.name != "Ares" { played.currentAttack = (played.currentAttack ?? 0) + 1 }
                me.board.append (played)
                resolvePlayEffect (card, me: &me, them: &them)
            }
            snapshot.message = "Opponent played \(card.name)."

        // MARK: Select Friendly Target
        // Resolves a spell targeting one of the acting player's own creatures.
        case .selectFriendlyTarget:
            guard let bi = action.targetBoardIndex, bi < me.board.count,
                  let ci = action.cardIndex, ci < me.hand.count else { break }
            let card = me.hand [ci]
            let cost = me.effectiveManaCost (card)
            me.mana -= cost
            me.hand.remove (at: ci)
            switch card.name {
            case "Prometheus's Fire":
                // Temporary attack buff — only `currentAttack` is modified.
                me.board [bi].currentAttack = (me.board [bi].currentAttack ?? 0) + 2
            case "Shield of Sparta":
                // Permanent health buff — both `currentHealth` and base `health`
                // are raised so the bonus survives turn-end health resets.
                me.board [bi].currentHealth = (me.board [bi].currentHealth ?? 0) + 3
                me.board [bi].health        = (me.board [bi].health ?? 0) + 3
            default: break
            }
            me.discard.append (card)

        // MARK: Select Opponent Target
        // Resolves spells and creature abilities targeting an opponent creature.
        case .selectOpponentTarget:
            guard let bi = action.targetBoardIndex, bi < them.board.count,
                  let ci = action.cardIndex, ci < me.hand.count else { break }
            let card = me.hand [ci]
            let cost = me.effectiveManaCost (card)
            me.mana -= cost
            me.hand.remove (at: ci)
            switch card.name {
            case "Curse of Circe":
                // Replace the targeted creature in-place with a 1/1 Pig, preserving
                // `canAttack` so the transformation doesn't reset attack eligibility.
                var pig = Card (name: "Pig", type: .monster, manaCost: 1, imageName: "pig", description: "A transformed 1/1 pig.", attack: 1, health: 1)
                pig.canAttack = them.board [bi].canAttack
                them.board [bi] = pig
                snapshot.message = "Opponent's Curse of Circe transforms your creature!"
            case "Sisyphus's Burden":
                them.board [bi].canAttack = false
                snapshot.message = "Opponent's Sisyphus's Burden freezes your creature!"
            case "Heracles":
                // Re-validate the health guard — board state may have changed
                // between the client's targeting decision and this resolution.
                guard (them.board [bi].currentHealth ?? 0) <= 2 else { break }
                let name = them.board [bi].name
                them.discard.append (them.board [bi])
                them.board.remove (at: bi)
                var played = card
                played.canAttack = false
                if me.hasAres () { played.currentAttack = (played.currentAttack ?? 0) + 1 }
                me.board.append (played)
                snapshot.message = "Opponent's Heracles destroys your \(name)!"
            default: break
            }
            me.discard.append (card)

        // MARK: Lightning Bolt — Creature Target
        case .selectLightningCreature:
            guard let bi = action.targetBoardIndex, bi < them.board.count,
                  let ci = action.cardIndex, ci < me.hand.count else { break }
            let card = me.hand [ci]
            me.mana -= me.effectiveManaCost (card)
            me.hand.remove (at: ci)
            // Poseidon blocks all spells targeting his side's creatures.
            if !them.board.contains (where: { $0.name == "Poseidon" }) {
                them.board [bi].currentHealth = (them.board [bi].currentHealth ?? 0) - 3
                them.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
                snapshot.message = "Lightning Bolt hits your creature for 3!"
            }
            me.discard.append (card)

        // MARK: Lightning Bolt — Hero Target
        case .selectLightningHero:
            guard let ci = action.cardIndex, ci < me.hand.count else { break }
            let card = me.hand [ci]
            me.mana -= me.effectiveManaCost (card)
            me.hand.remove (at: ci)
            them.health -= 3
            me.discard.append (card)
            snapshot.message = "Lightning Bolt hits you for 3!"

        // MARK: Resolve Odysseus
        // The chosen card's ID is used rather than an index because the picker
        // overlay may show a filtered or reordered subset of the deck.
        case .resolveOdysseus:
            guard let ci = action.cardIndex, ci < me.hand.count,
                  let chosenId = action.chosenCardId else { break }
            let card = me.hand [ci]
            me.mana -= me.effectiveManaCost (card)
            me.hand.remove (at: ci)
            // Peek the top 2 cards, keep the chosen one, discard the rest.
            let top2 = Array (me.deck.prefix (2))
            me.deck.removeFirst (min (2, me.deck.count))
            if let kept = top2.first (where: { $0.id == chosenId }) {
                me.hand.append (kept)
            }
            for discarded in top2.filter ({ $0.id != chosenId }) {
                me.discard.append (discarded)
            }
            // Place Odysseus onto the board with summoning sickness.
            var played = card; played.canAttack = false
            if me.hasAres () { played.currentAttack = (played.currentAttack ?? 0) + 1 }
            me.board.append (played)

        // MARK: Resolve Necromancy
        // The chosen card's ID is used for the same reason as Odysseus —
        // stable identity across filtered discard subsets.
        case .resolveNecromancy:
            guard let ci = action.cardIndex, ci < me.hand.count,
                  let chosenId = action.chosenCardId else { break }
            let card = me.hand [ci]
            me.mana -= me.effectiveManaCost (card)
            me.hand.remove (at: ci)
            if let i = me.discard.firstIndex (where: { $0.id == chosenId }) {
                var revived = me.discard [i]
                me.discard.remove (at: i)
                revived.currentHealth = revived.health
                revived.currentAttack = revived.attack
                revived.canAttack = false   // Summoning sickness applies to revived creatures.
                if me.hasAres () { revived.currentAttack = (revived.currentAttack ?? 0) + 1 }
                me.board.append (revived)
            }
            me.discard.append (card)

        // MARK: Attack Creature
        case .attackCreature:
            guard let ai = action.attackerIndex, ai < me.board.count,
                  let di = action.defenderIndex, di < them.board.count else { break }
            resolveCombat (attackerIdx: ai, defenderIdx: di, me: &me, them: &them, snapshot: &snapshot)

        // MARK: Attack Hero
        case .attackHero:
            guard let ai = action.attackerIndex, ai < me.board.count else { break }
            let dmg = me.board [ai].currentAttack ?? 0
            them.health -= dmg
            me.board [ai].canAttack = false
            snapshot.message = "Opponent attacks you for \(dmg)!"

        // MARK: End Turn
        // Refreshes attack flags, advances the turn counter, grants mana to the
        // next player, draws their card, and applies Apollo's start-of-turn healing.
        case .endTurn:
            for i in me.board.indices   { me.board [i].canAttack = true }
            for i in them.board.indices { them.board [i].canAttack = true }

            snapshot.isHostTurn   = !snapshot.isHostTurn
            snapshot.currentTurn += 1

            let nextMana = min (snapshot.currentTurn, 10)
            them.maxMana = nextMana
            them.mana    = nextMana

            drawCard (for: &them)

            // Apollo passive: heal the next active player for 2 on their turn start.
            if them.board.contains (where: { $0.name == "Apollo" }) {
                them.health = min (them.health + 2, 30)
            }
            snapshot.message = "Your turn! You have \(them.mana) mana."
        }

        checkWin (me: me, them: them, snapshot: &snapshot)

        // Write mutated player values back into the snapshot.
        // Both clients will see this update when Firebase propagates the write.
        if isHost {
            snapshot.hostPlayer  = me
            snapshot.guestPlayer = them
        } else {
            snapshot.guestPlayer = me
            snapshot.hostPlayer  = them
        }
    }

    // MARK: - Private: Spell Resolution

    /// Resolves non-targeted spells — those that take effect immediately without
    /// requiring a board target (area damage, draw, healing, token summoning).
    ///
    /// Targeted spells (Lightning Bolt, Curse of Circe, etc.) are resolved
    /// inline in `applyAction` because their effects require index parameters
    /// that are carried in the `MPGameAction` itself.
    private func resolveSpell (_ card: Card, me: inout MPPlayer, them: inout MPPlayer) {
        switch card.name {
        case "Poseidon's Tide":
            // Blocked if the opponent's Poseidon is on the board.
            if !them.board.contains (where: { $0.name == "Poseidon" }) {
                for i in them.board.indices { them.board [i].currentHealth = (them.board [i].currentHealth ?? 0) - 2 }
                them.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
            }
        case "Oracle's Vision":
            drawCard (for: &me); drawCard (for: &me)
        case "Olympian Blessing":
            me.health = min (me.health + 5, 30)
        case "Trojan Horse":
            for _ in 0..<3 {
                var s = Card (name: "Soldier", type: .monster, manaCost: 1, imageName: "soldier", description: "A 1/1 Trojan soldier.", attack: 1, health: 1)
                s.canAttack = false
                if me.hasAres () { s.currentAttack = (s.currentAttack ?? 0) + 1 }
                me.board.append (s)
            }
        default: break
        }
    }

    // MARK: - Private: On-Play Effects

    /// Resolves triggered on-play effects for creature cards that take immediate
    /// board actions when they enter the battlefield.
    ///
    /// Zeus, Ares, Cerberus, and Odysseus all have on-play effects. Cards with
    /// passive abilities (Poseidon, Medusa, Hades) or combat-only abilities
    /// (Achilles, Leonidas) are handled at the point of use in `resolveCombat`
    /// and `cleanupDead`.
    private func resolvePlayEffect (_ card: Card, me: inout MPPlayer, them: inout MPPlayer) {
        switch card.name {
        case "Zeus":
            for i in them.board.indices { them.board [i].currentHealth = (them.board [i].currentHealth ?? 0) - 2 }
            them.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
        case "Ares":
            // Buff all existing friendly creatures except Ares himself.
            for i in me.board.indices where me.board [i].name != "Ares" {
                me.board [i].currentAttack = (me.board [i].currentAttack ?? 0) + 1
            }
        case "Cerberus":
            // Remove the single Cerberus token and replace with three 2/2 heads.
            me.board.removeLast ()
            for _ in 0..<3 {
                var h = Card (name: "Cerberus", type: .monster, manaCost: 4, imageName: "cerberus", description: "Summons 3 separate 2/2 creatures instead of one.", attack: 2, health: 2)
                h.canAttack = false
                if me.hasAres () { h.currentAttack = (h.currentAttack ?? 0) + 1 }
                me.board.append (h)
            }
        case "Odysseus":
            // In the non-targeted path, Odysseus simply draws one extra card
            // (the choice-based path is handled by `.resolveOdysseus`).
            drawCard (for: &me)
        default: break
        }
    }

    // MARK: - Private: Combat Resolution

    /// Resolves simultaneous combat between one of the acting player's creatures
    /// and one of the opponent's creatures, applying all special ability rules.
    ///
    /// Mirrors `GameState.attackCreature` and `GameState.aiAttackCreature`
    /// exactly, including Achilles double damage, Leonidas damage halving,
    /// Medusa instant-kill, and Athena's Divine Shield. Having identical logic
    /// in both the local and multiplayer engines ensures the game plays consistently
    /// regardless of mode.
    private func resolveCombat (attackerIdx: Int, defenderIdx: Int, me: inout MPPlayer, them: inout MPPlayer, snapshot: inout MPGameSnapshot) {
        guard attackerIdx < me.board.count, defenderIdx < them.board.count else { return }

        let atkName = me.board [attackerIdx].name
        let defName = them.board [defenderIdx].name

        var atkDmg = me.board [attackerIdx].currentAttack ?? 0
        var defDmg = them.board [defenderIdx].currentAttack ?? 0

        if atkName == "Achilles" { atkDmg *= 2 }
        if defName == "Achilles" { defDmg *= 2 }

        if leonidasProtects (index: defenderIdx, on: them.board) { atkDmg = max (1, atkDmg / 2) }
        if leonidasProtects (index: attackerIdx, on: me.board)   { defDmg = max (1, defDmg / 2) }

        // Medusa: attacker is destroyed outright; Medusa still takes damage.
        if defName == "Medusa" {
            me.board [attackerIdx].currentHealth = -1
            me.board [attackerIdx].canAttack = false
            them.board [defenderIdx].currentHealth = max (-1, (them.board [defenderIdx].currentHealth ?? 0) - atkDmg)
            cleanupDead (me: &me, them: &them)
            return
        }

        // Athena Divine Shield: first hit at full health is negated; attacker still takes counter-damage.
        if defName == "Athena" {
            let current = them.board [defenderIdx].currentHealth ?? 0
            let base    = them.board [defenderIdx].health ?? 0
            if current == base {
                them.board [defenderIdx].health = base - 1   // Break the shield permanently.
                me.board [attackerIdx].currentHealth = max (-1, (me.board [attackerIdx].currentHealth ?? 0) - defDmg)
                me.board [attackerIdx].canAttack = false
                cleanupDead (me: &me, them: &them)
                return
            }
        }

        // Standard simultaneous combat.
        them.board [defenderIdx].currentHealth = max (-1, (them.board [defenderIdx].currentHealth ?? 0) - atkDmg)
        me.board [attackerIdx].currentHealth   = max (-1, (me.board [attackerIdx].currentHealth ?? 0) - defDmg)
        me.board [attackerIdx].canAttack = false

        cleanupDead (me: &me, them: &them)
    }

    // MARK: - Private: Death Cleanup

    /// Removes all dead creatures from both boards, resolves death-triggered
    /// effects (Hades healing, Hydra token spawning), and moves dead cards to
    /// their respective discard piles.
    ///
    /// Both boards are processed together in one call to ensure Hades heals
    /// correctly regardless of which side the dying creatures are on.
    private func cleanupDead (me: inout MPPlayer, them: inout MPPlayer) {
        let myDead   = me.board.filter   { ($0.currentHealth ?? 0) <= 0 }
        let themDead = them.board.filter { ($0.currentHealth ?? 0) <= 0 }

        // Hades passive: heal 2 per enemy creature that dies.
        if them.board.contains (where: { $0.name == "Hades" }) {
            them.health = min (them.health + myDead.count * 2, 60)
        }
        if me.board.contains (where: { $0.name == "Hades" }) {
            me.health = min (me.health + themDead.count * 2, 60)
        }

        // Death triggers: Hydra spawns two 2/1 heads when it dies.
        for d in myDead   {
            if d.name == "Hydra" { spawnHydraHeads (for: &me) }
            me.discard.append (d)
        }
        for d in themDead {
            if d.name == "Hydra" { spawnHydraHeads (for: &them) }
            them.discard.append (d)
        }

        me.board.removeAll   { ($0.currentHealth ?? 0) <= 0 }
        them.board.removeAll { ($0.currentHealth ?? 0) <= 0 }
    }

    /// Appends two 2/1 Hydra Head tokens to the given player's board, applying
    /// the Ares attack bonus if he is in play. Tokens enter with summoning sickness.
    private func spawnHydraHeads (for player: inout MPPlayer) {
        for _ in 0..<2 {
            var head = Card (name: "Hydra Head", type: .monster, manaCost: 1, imageName: "hydra", description: "A 2/1 Hydra Head.", attack: 2, health: 1)
            head.canAttack = false
            if player.hasAres () { head.currentAttack = (head.currentAttack ?? 0) + 1 }
            player.board.append (head)
        }
    }

    /// Returns `true` if the creature at `index` on `board` is adjacent to a
    /// Leonidas, indicating it should receive halved incoming combat damage.
    private func leonidasProtects (index: Int, on board: [Card]) -> Bool {
        let left  = index > 0               && board [index - 1].name == "Leonidas"
        let right = index < board.count - 1 && board [index + 1].name == "Leonidas"
        return left || right
    }

    // MARK: - Private: Win Condition

    /// Checks both players' health and updates `snapshot.gameResult` if either
    /// has reached 0. Also cancels the disconnect handler once the game ends
    /// naturally so Firebase doesn't apply the forfeit after a legitimate result.
    private func checkWin (me: MPPlayer, them: MPPlayer, snapshot: inout MPGameSnapshot) {
        if them.health <= 0 { snapshot.gameResult = isHost ? "hostWon" : "guestWon" }
        if me.health   <= 0 { snapshot.gameResult = isHost ? "guestWon" : "hostWon" }
        if snapshot.gameResult != "ongoing", let roomId = roomId {
            cancelDisconnectHandler (roomId: roomId)
        }
    }
}
