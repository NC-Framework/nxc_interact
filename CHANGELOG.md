# Changelog

Entries are added only for genuinely user-visible or contract-relevant changes.

## 0.1.1 - 2026-08-03

### Added

- `begin(source, workflowKey)` on the server, so a resource can start a workflow
  for a player.

  **nxc_interact could only be started by the client**, and a nxc_target option
  handler runs on the server with a validated context and no client to ask - so
  the two resources did not compose at all. The handler that had just been told a
  player may pick a lock had no way to make them stand there and do it.

  Both entry points share one implementation. Two copies of the checks drift, and
  one path quietly becomes the weak one.

  A resource starting a workflow does **not** bypass the capability check. A
  resource asking on a player's behalf is not the same as the player being
  entitled.

### Changed

- Refusals are structured error codes rather than bare words, matching every
  other refusal in the framework.

## Unreleased

## 0.2.0 — 2026-08-05

### Added

- Registers itself as a service with nxc_core, and exports `health`.


Initial implementation of the interaction workflow service.

### Added

- Workflows: animation, prop, progress, and skill-check steps with a duration, an
  optional cooldown, and an outcome.

- **A server gate that measures the duration itself.** The server starts the
  workflow and records when; a completion arriving before the declared duration
  is refused. A player who deletes the client half entirely still waits.

- Skill checks that say who decides. `decidedBy = server` means the server rolls
  and the minigame is presentation. `decidedBy = client` is accepted, because a
  skill check that only affects flavour is legitimate, and registration warns
  that the player is deciding. Server is the default, so forgetting to choose is
  the safe choice.

- Cooldowns per player per workflow, cleared on disconnect and pruned
  periodically.

- Cancellation on Escape or death, and cleanup on every exit path. **A cancelled
  workflow sets no cooldown** — punishing a cancelled action makes cancelling
  worse than never starting.

- 49 tests, 13 of which drive the gate the way a modified client would.

### Known limitations

- **This resource owns no items and no money.** Consumption and reward are
  requests to whichever resource owns those. Neither exists yet, so a workflow
  declaring either is refused at the start rather than completed with the request
  silently dropped.

- **There is no transaction across the two.** If a reward fails after a
  consumption succeeded, the consumption is not undone. That needs a transaction
  spanning two resources this one does not own, and it is logged rather than
  solved.

- A client-decided skill check cannot be verified, by construction.

- Nothing here has run on a server.

Initial development. No release has been made.
