# Matchmaking: how a ghost is picked for a fight

How the game chooses the opponent you face each day, and how the mod feeds
that choice. Behavior described is the live game's own; script and function
names (`RunDatabase.sortOpponents`, `RunData.deserializeRound`, …) anchor
each claim to the game scripts the mod already reads.

## Fight booking

Each time you press "fight" on day N:

1. The game snapshots your board (`RunDatabase.serializeCurrentRound`) —
   the exact board you fight with.
2. `RunDatabase.sortOpponents` rebuilds the candidate pool: every run with
   at least N boards (`getNumRounds() >= Game.curRound`), shuffled, then
   scored (see below) and sorted cheapest-first.
3. The cheapest run fights. If its board fails inventory validation, the
   game pops it (`notifyOpponentCorrupt`) and tries the next candidate.

## Board day parity

Ghosts fight with their day-N board. Both sides record boards at the same
moment — combat start of the same round number — and
`RunData.deserializeRound(Game.curRound)` reads `rounds[N - 1]` from the
ghost, filled in fixed key order `"0".."17"`. There is no day offset: your
day 5 board meets the ghost's day 5 board.

## Matchmaking score

Lower score wins. Per candidate, added up each fight:

| Term | Score |
|---|---|
| Player's own steam id / own name | +10000 / +5000 |
| Ranked-vs-unranked mismatch | +1000 |
| Rematch within the last 12 fights | up to +1100 (hardest right after) |
| Class variety | ±0.1; a 3rd same-class fight in a row +22 |
| Ghost wins vs player wins | +10 per win the ghost has more, +5 per win it has fewer |
| Perfect ghost (10 wins already) | +1000 — effectively excluded |
| Rating distance | +clamp(\|Δr\| / 1000, 0, 1); +12 if \|Δr\| > 150 |
| Randomness | +0 … 0.05 |

Notes:

- The win term compares the ghost's wins through day N−1 with the player's
  current wins — symmetric bookkeeping, and asymmetric penalties: missing a
  win costs the ghost half of what an extra win costs. The pool therefore
  skews equal-or-weaker, never stronger.
- Below Master league, half the fights target one win *fewer* than the
  player has — an explicit easy bias.

## Mercy handicaps

On top of selection, the game weakens the opponent when the player
struggles (only outside Lobbies/Switch mode):

- **Item handicap** — on losing-streak records (0W2L, 1W3L, 2W4L, 3W4L,
  0W4L) below Diamond league: the opponent loses one random non-bag,
  non-weapon item.
- **Softball round** — for early runs or a run rating ≤ 80, on a
  round-parity schedule (most rounds of runs 1–3, every 4th round later):
  the opponent's *items* come from `N − 1`. Below Diamond, mercy records
  (0W3L, ≤1W4L) add a second reduction: items from `N − 2`. Health and
  stamina always stay at day N.
- Guard: reductions never go before round 1; if they would, items stay and
  the item handicap applies instead.

All of these make the opponent weaker. Nothing in the game's selection
biases toward opponents the player is likely to lose to.

## Where the mod plugs in

The mod replaces the pool, not the choice. `parsedRuns` is filled from
`ghosts.gdb`: dense ranks within ±1000 of the player's rank estimate
(60000 in statistics mode), minus exclusions, refilled per `CONTEXT.md` if
exclusions gut the window. The game then books fights exactly as above.

Known sharp edge: the window is centered on one cached `r` from the last
uploaded run, while the game's ratings are per class. Switching classes
anchors the window to the previous class's strength until the next upload.
