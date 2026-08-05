--- The server half: starting workflows, and deciding whether they finished.
---
--- **THE SERVER STARTS THE WORKFLOW.** A client does not announce that it began
--- something and then announce that it finished — it asks to begin, and the
--- server records when it said yes. That recorded time is what every later
--- decision is measured against.
---
--- Without it there is no enforcement at all: a client that reports both ends of
--- an interval controls the interval.
---
--- **THIS RESOURCE OWNS NO ITEMS AND NO MONEY.** `consumes` and `rewards` are
--- requests handed to whichever resource owns those. Neither exists yet, so a
--- workflow declaring either is refused rather than completed with the request
--- silently dropped — a crafting recipe that consumes nothing and produces
--- nothing looks like it worked.

if not IsDuplicityVersion() then return end

local Service = {}

local registry = {}
local state = NxcInteract.Sessions.new()

--- Providers for the things this resource deliberately does not own.
---
--- Registered by whoever owns them. Absent until Phase 3, and absence is a
--- refusal rather than a shrug.
local providers = { items = nil, rewards = nil }

---@param name string  'items' or 'rewards'
---@param provider function
function Service.setProvider(name, provider)
    if providers[name] == nil and name ~= 'items' and name ~= 'rewards' then
        error(('unknown provider: %s'):format(tostring(name)), 2)
    end
    if type(provider) ~= 'function' then
        error('a provider must be a function', 2)
    end
    providers[name] = provider
    Nxc.Logger.info('interact.provider_registered', { provider = name })
end

local function key(owner, id) return owner .. ':' .. id end

--- Register a workflow.
---
---@param workflow table
---@param owner string
---@return NxcResult
function Service.register(workflow, owner)
    if type(owner) ~= 'string' or owner == '' then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = {
            { field = 'owner', reason = 'a workflow must belong to a resource' } } }))
    end

    local valid = NxcInteract.Workflow.validate(workflow)
    if not valid.ok then return valid end

    local stored = {}
    for k, v in pairs(workflow) do stored[k] = v end
    stored.owner = owner
    stored.key = key(owner, workflow.id)

    registry[stored.key] = stored

    if valid.value.advisory then
        Nxc.Logger.warn('interact.client_decided_outcome', {
            workflow = stored.key, registeringResource = owner,
            detail = valid.value.advisory,
        })
    end

    return Nxc.Result.ok({ key = stored.key, advisory = valid.value.advisory })
end

--- Begin a workflow for a player.
---
--- **THE ONLY PATH IN, AND BOTH CALLERS USE IT.** A client may ask directly, and
--- a resource may start one on a player's behalf — which is what a nxc_target
--- option handler does, since that is where the validated context lands and it
--- runs on the server with no client to ask.
---
--- Without this export the two resources do not compose: the handler that has
--- just been told a player may pick a lock has no way to make them stand there
--- and do it.
---
---@param source any
---@param workflowKey string
---@return NxcResult
function Service.begin(source, workflowKey)
    local workflow = registry[workflowKey]
    if not workflow then
        return Nxc.Result.err(Nxc.Errors.new('NXC_INTERACT_UNKNOWN_WORKFLOW',
            'That is not a workflow.',
            { resource = NxcInteract.RESOURCE, details = { workflow = tostring(workflowKey) } }))
    end

    -- Capability, from the session rather than from anything the caller passed.
    -- Checked even when a resource starts the workflow: a resource asking on a
    -- player's behalf is not the same as the player being entitled, and the two
    -- diverge the moment one resource trusts another's reasoning.
    if workflow.capability then
        local ok, held = pcall(function()
            return exports.nxc_core:hasCapability(source, workflow.capability)
        end)
        if not ok or held ~= true then
            return Nxc.Result.err(Nxc.Errors.forbidden(workflow.capability))
        end
    end

    -- Anything that cannot be honoured is refused BEFORE the player waits for
    -- it. Refusing after the animation is a worse experience for identical
    -- safety.
    if workflow.consumes and not providers.items then
        return Nxc.Result.err(Nxc.Errors.new('NXC_INTERACT_UNAVAILABLE',
            'That is not available right now.',
            { resource = NxcInteract.RESOURCE,
              details = { reason = 'no inventory provider is registered' } }))
    end
    if workflow.rewards and not providers.rewards then
        return Nxc.Result.err(Nxc.Errors.new('NXC_INTERACT_UNAVAILABLE',
            'That is not available right now.',
            { resource = NxcInteract.RESOURCE,
              details = { reason = 'no reward provider is registered' } }))
    end

    local correlationId = Nxc.Correlation.new()
    local started = NxcInteract.Sessions.start(
        state, source, workflow, Nxc.Time.nowMs(), correlationId)
    if not started.ok then return started end

    TriggerClientEvent('nxc_interact:client:begin', source, {
        key = workflow.key,
        durationMs = workflow.durationMs,
        steps = Nxc.plain(workflow.steps or {}),
        correlationId = correlationId,
    })

    return Nxc.Result.ok({ key = workflow.key, correlationId = correlationId })
end

--- A client asking to begin.
RegisterNetEvent('nxc_interact:server:start', function(request)
    local source = source

    if type(request) ~= 'table' or type(request.key) ~= 'string' then return end

    local result = Service.begin(source, request.key)
    if not result.ok then
        Nxc.Logger.warn('interact.start_refused', {
            connection = tostring(source), workflow = tostring(request.key),
            reason = result.error.code,
            details = result.error.details,
        })
        TriggerClientEvent('nxc_interact:client:refused', source,
            request.key, result.error.code, Nxc.plain(result.error.details))
    end
end)

--- A client reporting that it finished.
---
--- **The only thing believed here is that the client stopped.** Whether enough
--- time passed is measured against the start this server recorded.
RegisterNetEvent('nxc_interact:server:complete', function(report)
    local source = source

    if type(report) ~= 'table' or type(report.key) ~= 'string' then return end

    local workflow = registry[report.key]
    if not workflow then return end

    local done = NxcInteract.Sessions.complete(
        state, source, report.key, workflow, Nxc.Time.nowMs())

    if not done.ok then
        Nxc.Logger.warn('interact.completion_refused', {
            connection = tostring(source), workflow = report.key,
            reason = done.error.code,
            details = done.error.details,
        })
        TriggerClientEvent('nxc_interact:client:refused', source, report.key, done.error.code)
        return
    end

    -- A client-decided skill check reports its own outcome, and nothing can
    -- verify it. Recorded as what it is so a later audit can tell a trusted
    -- outcome from a claimed one.
    local outcome = report.success ~= false
    local outcomeDecidedBy = 'server'
    for _, step in ipairs(workflow.steps or {}) do
        if step.kind == NxcInteract.Workflow.STEP.SKILL then
            if (step.decidedBy or 'server') == 'client' then
                outcomeDecidedBy = 'client'
            else
                -- The server rolls. The minigame the player saw was presentation.
                outcome = math.random() >= (step.difficulty or 0.5)
            end
        end
    end

    local context = {
        source = source,
        account = exports.nxc_core:accountFor(source),
        character = exports.nxc_core:characterFor(source),
        workflow = workflow.key,
        elapsedMs = done.value.elapsedMs,
        success = outcome,
        outcomeDecidedBy = outcomeDecidedBy,
        correlationId = done.value.correlationId,
    }

    if outcome and workflow.consumes then
        local ok, consumed = pcall(providers.items, source, Nxc.plain(workflow.consumes))
        if not ok or consumed ~= true then
            Nxc.Logger.warn('interact.consumption_refused', {
                workflow = workflow.key, correlationId = context.correlationId,
            })
            TriggerClientEvent('nxc_interact:client:refused', source, workflow.key, 'consume_failed')
            return
        end
    end

    if outcome and workflow.rewards then
        -- Requested, not granted. A failure here is logged and does not undo the
        -- consumption, which is a real gap: this resource has no transaction
        -- spanning two resources it does not own.
        local ok = pcall(providers.rewards, source, Nxc.plain(workflow.rewards))
        if not ok then
            Nxc.Logger.error('interact.reward_failed', {
                workflow = workflow.key, correlationId = context.correlationId,
                detail = 'the consumption already happened and is not undone',
            })
        end
    end

    if workflow.onComplete then
        local dispatched, err = pcall(TriggerEvent, workflow.onComplete, context)
        if not dispatched then
            Nxc.Logger.error('interact.handler_failed', {
                workflow = workflow.key, event = workflow.onComplete, reason = tostring(err),
            })
        end
    end

    TriggerClientEvent('nxc_interact:client:finished', source, workflow.key, outcome)
end)

RegisterNetEvent('nxc_interact:server:cancel', function()
    local abandoned = NxcInteract.Sessions.abandon(state, source)
    if abandoned then
        Nxc.Logger.debug('interact.cancelled', {
            connection = tostring(source), workflow = abandoned.workflowId,
        })
    end
end)

AddEventHandler('playerDropped', function()
    NxcInteract.Sessions.forget(state, source)
end)

--- A resource stopping takes its workflows, and abandons anything in flight for
--- one of them. A player left mid-workflow for a resource that no longer exists
--- can never complete it and would never be able to start anything again.
AddEventHandler('onResourceStop', function(resource)
    local removed = 0
    for k, workflow in pairs(registry) do
        if workflow.owner == resource then registry[k] = nil removed = removed + 1 end
    end
    if removed == 0 then return end

    for player, flight in pairs(state.inFlight) do
        if not registry[flight.workflowId] then
            NxcInteract.Sessions.abandon(state, player)
            TriggerClientEvent('nxc_interact:client:refused', player,
                flight.workflowId, 'owner_stopped')
        end
    end
    Nxc.Logger.info('interact.owner_stopped', { stoppedResource = resource, removed = removed })
end)

CreateThread(function()
    while true do
        Wait(60000)
        NxcInteract.Sessions.prune(state, Nxc.Time.nowMs())
    end
end)

exports('register', function(workflow)
    local owner = GetInvokingResource() or NxcInteract.RESOURCE
    return Nxc.plain(Service.register(workflow, owner))
end)

--- Start a workflow for a player, from a resource.
---
--- This is how nxc_target and nxc_interact compose: a target option's server
--- handler receives a validated context and calls this with the connection it
--- was given.
exports('begin', function(source, workflowKey)
    return Nxc.plain(Service.begin(source, workflowKey))
end)

exports('setItemProvider', function(fn) Service.setProvider('items', fn) end)
exports('setRewardProvider', function(fn) Service.setProvider('rewards', fn) end)

RegisterCommand('nxc_interact_status', function(source)
    if source ~= 0 then return end

    local count, unverifiable = 0, 0
    for _, workflow in pairs(registry) do
        count = count + 1
        for _, step in ipairs(workflow.steps or {}) do
            if step.kind == NxcInteract.Workflow.STEP.SKILL
                and (step.decidedBy or 'server') == 'client' then
                unverifiable = unverifiable + 1
                break
            end
        end
    end

    local inFlight = 0
    for _ in pairs(state.inFlight) do inFlight = inFlight + 1 end

    print(('^5[nxc_interact]^7 v%s, contract v%d')
        :format(NxcInteract.VERSION, NxcInteract.CONTRACT_VERSION))
    print(('  registered workflows  %d'):format(count))
    print(('  in flight now         %d'):format(inFlight))
    print(('  item provider         %s')
        :format(providers.items and 'registered' or '^3none — workflows that consume are refused^7'))
    print(('  reward provider       %s')
        :format(providers.rewards and 'registered' or '^3none — workflows that reward are refused^7'))
    if unverifiable > 0 then
        print(('  ^3%d workflows whose outcome the client decides^7'):format(unverifiable))
    end
    if count == 0 then
        print('    nothing registered yet — no resource has called nxc_interact:register')
    end
end, true)

Nxc.Service.start({
    dependencies = { 'nxc_lib', 'nxc_target', 'nxc_ui' },
    contractVersion = NxcInteract.CONTRACT_VERSION,
    capabilities = { 'workflows' },
    ready = true,
})

--- This resource's own health, for nxc_core's aggregate and for anyone asking
--- directly. Plain, because a report behind a metatable arrives empty.
exports('health', function() return Nxc.plain(Nxc.Health.report()) end)

NxcInteract.Service = Service
return Service
