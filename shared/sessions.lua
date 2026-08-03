--- In-flight workflows and cooldowns.
---
--- Pure bookkeeping: who started what, when, and when they may do it again.
--- Every decision the server gate makes about timing is made here, where it can
--- be tested against a clock that does not move on its own.
---
--- **ONE WORKFLOW PER PLAYER AT A TIME.** A second start is refused rather than
--- replacing the first. Replacing it would let a player begin a five second
--- action, immediately begin it again, and have two completions in flight for
--- one wait — and the cheapest exploits are always the ones where the honest
--- path and the dishonest path differ by a single extra call.

local Sessions = {}

---@return table
function Sessions.new()
    return { inFlight = {}, cooldowns = {} }
end

--- The identity a workflow is tracked by.
---
--- **`key` WHEN THERE IS ONE, `id` OTHERWISE**, and it must be the same choice
--- everywhere. The registry stores workflows under `owner:id` so two resources
--- can each have a `dig`; if the in-flight record and the cooldown used the bare
--- id instead, two things would break at once — every completion would mismatch
--- its own start, and those two `dig` workflows would share one cooldown.
---
--- Both of those happened. The first was loud and the second would not have been.
---
---@param workflow table
---@return string
local function identityOf(workflow)
    return workflow.key or workflow.id
end

--- The key a cooldown is recorded against.
---
--- Per player per workflow. A global cooldown would make one player's action
--- block everyone else's; a per-player-only cooldown would make a long workflow
--- block a short unrelated one.
local function cooldownKey(player, workflow)
    return tostring(player) .. '|' .. identityOf(workflow)
end

--- May this player start this workflow now?
---
---@param state table
---@param player any
---@param workflow table
---@param nowMs number
---@return NxcResult
function Sessions.canStart(state, player, workflow, nowMs)
    if state.inFlight[player] then
        return Nxc.Result.err(Nxc.Errors.new('NXC_INTERACT_ALREADY_BUSY',
            'You are already doing something.',
            { resource = NxcInteract.RESOURCE,
              details = { current = state.inFlight[player].workflowId } }))
    end

    local readyAt = state.cooldowns[cooldownKey(player, workflow)]
    if readyAt and nowMs < readyAt then
        return Nxc.Result.err(Nxc.Errors.new('NXC_INTERACT_COOLDOWN',
            'You cannot do that again yet.',
            { resource = NxcInteract.RESOURCE,
              details = { retryAfterMs = readyAt - nowMs } }))
    end

    return Nxc.Result.ok(true)
end

--- Record a start.
---
---@return NxcResult
function Sessions.start(state, player, workflow, nowMs, correlationId)
    local allowed = Sessions.canStart(state, player, workflow, nowMs)
    if not allowed.ok then return allowed end

    state.inFlight[player] = {
        workflowId = identityOf(workflow),
        startedAtMs = nowMs,
        durationMs = workflow.durationMs,
        correlationId = correlationId,
    }
    return Nxc.Result.ok(state.inFlight[player])
end

--- Record a completion, if it is honest.
---
--- **The elapsed time is measured here, from the start this server recorded.**
--- Nothing the client reports about timing is consulted, because a client that
--- can report completion can report any elapsed time it likes.
---
---@param state table
---@param player any
---@param workflowId string
---@param workflow table
---@param nowMs number
---@return NxcResult
function Sessions.complete(state, player, workflowId, workflow, nowMs)
    local flight = state.inFlight[player]

    if not flight then
        -- Either a completion for something never started, or one arriving after
        -- a cancellation. Both are refused; the first is the interesting one.
        return Nxc.Result.err(Nxc.Errors.new('NXC_INTERACT_NOT_STARTED',
            'That was not started.',
            { resource = NxcInteract.RESOURCE }))
    end

    if flight.workflowId ~= workflowId then
        -- Started one thing, claimed to finish another. Refusing on identity as
        -- well as timing is what stops a long workflow being started and a short
        -- one completed.
        return Nxc.Result.err(Nxc.Errors.new('NXC_INTERACT_WRONG_WORKFLOW',
            'That was not what you started.',
            { resource = NxcInteract.RESOURCE,
              details = { started = flight.workflowId, claimed = workflowId } }))
    end

    local elapsedMs = nowMs - flight.startedAtMs
    if not NxcInteract.Workflow.durationSatisfied(workflow, elapsedMs) then
        state.inFlight[player] = nil
        return Nxc.Result.err(Nxc.Errors.new('NXC_INTERACT_TOO_FAST',
            'That did not take long enough.',
            { resource = NxcInteract.RESOURCE,
              details = { elapsedMs = elapsedMs, requiredMs = workflow.durationMs } }))
    end

    state.inFlight[player] = nil

    if workflow.cooldownMs and workflow.cooldownMs > 0 then
        state.cooldowns[cooldownKey(player, workflow)] = nowMs + workflow.cooldownMs
    end

    return Nxc.Result.ok({ elapsedMs = elapsedMs, correlationId = flight.correlationId })
end

--- Abandon whatever a player was doing.
---
--- Cancellation, death, disconnection, or a resource stopping. Always succeeds:
--- a cleanup path that can fail is one that sometimes does not run, and the
--- residue here is a player who can never start anything again.
---
--- **A cancelled workflow sets no cooldown.** Punishing a player for a cancelled
--- action makes cancellation a worse outcome than never starting, which is
--- exactly backwards for the one control they have.
---
---@param state table
---@param player any
---@return table|nil  what was abandoned
function Sessions.abandon(state, player)
    local flight = state.inFlight[player]
    state.inFlight[player] = nil
    return flight
end

--- Forget a player entirely.
---
--- On disconnect. Their cooldowns go with them — a cooldown is a limit on a
--- player's rate of action, and a player who is gone has no rate.
---
---@param state table
---@param player any
function Sessions.forget(state, player)
    state.inFlight[player] = nil

    local prefix = tostring(player) .. '|'
    local stale = {}
    for key in pairs(state.cooldowns) do
        if key:sub(1, #prefix) == prefix then stale[#stale + 1] = key end
    end
    for _, key in ipairs(stale) do state.cooldowns[key] = nil end
end

--- Drop cooldowns that have expired.
---
--- Called periodically. Without it the table grows with every distinct player
--- and workflow the server has ever seen, which is slow rather than wrong — and
--- slow rather than wrong is how a table becomes a memory problem.
---
---@param state table
---@param nowMs number
---@return number removed
function Sessions.prune(state, nowMs)
    local expired = {}
    for key, readyAt in pairs(state.cooldowns) do
        if nowMs >= readyAt then expired[#expired + 1] = key end
    end
    for _, key in ipairs(expired) do state.cooldowns[key] = nil end
    return #expired
end

---@param state table
---@param player any
---@return table|nil
function Sessions.inFlight(state, player) return state.inFlight[player] end

NxcInteract.Sessions = Sessions
return Sessions
