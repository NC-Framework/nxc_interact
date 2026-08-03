--- What a workflow is, and what makes one valid.
---
--- A workflow is a named sequence of steps with a duration, an optional
--- cooldown, and an outcome. It is registered on the server; the client is told
--- how to perform it.
---
--- **THE DURATION IS THE CONTRACT.** Everything else — which animation, which
--- prop, whether there is a progress bar — is presentation, and a player who
--- strips all of it still waits the same time, because the server measures
--- against its own clock rather than believing a report.

local Workflow = {}

Workflow.STEP = {
    ANIMATION = 'animation',
    PROP      = 'prop',
    PROGRESS  = 'progress',
    SKILL     = 'skillCheck',
}

--- How a skill check's outcome is decided.
---
--- **`client` MEANS THE PLAYER DECIDES.** A minigame runs on their machine and
--- reports whether they succeeded; nothing can verify that. It is offered
--- because a skill check that only affects flavour is a legitimate and common
--- thing, and pretending otherwise would push authors to fake it.
---
--- **`server` MEANS THE SERVER DECIDES**, and the minigame is presentation. Use
--- this whenever the outcome matters — whether an item is produced, whether a
--- lock opens, whether a theft succeeds.
Workflow.DECIDED_BY = { CLIENT = 'client', SERVER = 'server' }

--- The longest a single workflow may run.
---
--- A ceiling rather than a suggestion. An in-flight workflow holds server state
--- per player, and one that never ends holds it forever — a player who
--- disconnects mid-workflow is handled, but a workflow declared to take an hour
--- is a leak with a schedule.
Workflow.MAX_DURATION_MS = 5 * 60 * 1000
Workflow.MIN_DURATION_MS = 100

--- How much early a completion may arrive before it is refused.
---
--- Not generosity. The client's timer and the server's differ by network latency
--- and a frame or two, and refusing a completion 40ms early would fail honest
--- players constantly.
---
--- Small, because it is subtracted from every duration. A player who can shave
--- 250ms off a five second action has gained nothing; one who could shave five
--- seconds has removed the action.
Workflow.COMPLETION_TOLERANCE_MS = 250

local function problem(field, reason)
    return { field = field, reason = reason }
end

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function validateStep(step, index, problems)
    local label = ('steps[%d]'):format(index)

    if type(step) ~= 'table' then
        problems[#problems + 1] = problem(label, 'must be a table')
        return
    end

    local known = false
    for _, kind in pairs(Workflow.STEP) do
        if kind == step.kind then known = true break end
    end
    if not known then
        problems[#problems + 1] =
            problem(label .. '.kind', ('unknown step kind: %s'):format(tostring(step.kind)))
        return
    end

    if step.kind == Workflow.STEP.ANIMATION then
        if type(step.dict) ~= 'string' or step.dict == '' then
            problems[#problems + 1] = problem(label .. '.dict', 'is required')
        end
        if type(step.anim) ~= 'string' or step.anim == '' then
            problems[#problems + 1] = problem(label .. '.anim', 'is required')
        end

    elseif step.kind == Workflow.STEP.PROP then
        if step.model == nil then
            problems[#problems + 1] = problem(label .. '.model', 'is required')
        end
        if type(step.bone) ~= 'number' then
            problems[#problems + 1] = problem(label .. '.bone', 'must be a bone index')
        end

    elseif step.kind == Workflow.STEP.PROGRESS then
        if type(step.label) ~= 'string' or step.label == '' then
            -- A progress bar with no label is a bar that tells a player nothing
            -- except that they cannot move.
            problems[#problems + 1] = problem(label .. '.label', 'a progress bar must say what it is doing')
        end

    elseif step.kind == Workflow.STEP.SKILL then
        local decidedBy = step.decidedBy or Workflow.DECIDED_BY.SERVER
        if decidedBy ~= Workflow.DECIDED_BY.CLIENT
            and decidedBy ~= Workflow.DECIDED_BY.SERVER then
            problems[#problems + 1] =
                problem(label .. '.decidedBy', "must be 'client' or 'server'")
        end
        if step.difficulty ~= nil then
            if not isFiniteNumber(step.difficulty)
                or step.difficulty < 0 or step.difficulty > 1 then
                problems[#problems + 1] =
                    problem(label .. '.difficulty', 'must be between 0 and 1')
            end
        end
    end
end

--- Validate a workflow definition.
---
---@param workflow table
---@return NxcResult
function Workflow.validate(workflow)
    if type(workflow) ~= 'table' then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { problem('workflow', 'must be a table') } }))
    end

    local problems = {}

    if type(workflow.id) ~= 'string' or workflow.id == '' then
        problems[#problems + 1] = problem('id', 'is required')
    end

    if not isFiniteNumber(workflow.durationMs) then
        problems[#problems + 1] = problem('durationMs', 'is required and must be a number')
    elseif workflow.durationMs < Workflow.MIN_DURATION_MS then
        problems[#problems + 1] = problem('durationMs',
            ('at least %d; anything shorter is not an action a player experiences')
                :format(Workflow.MIN_DURATION_MS))
    elseif workflow.durationMs > Workflow.MAX_DURATION_MS then
        problems[#problems + 1] = problem('durationMs',
            ('at most %d; an in-flight workflow holds server state, and one that '
             .. 'never ends holds it forever'):format(Workflow.MAX_DURATION_MS))
    end

    if workflow.cooldownMs ~= nil then
        if not isFiniteNumber(workflow.cooldownMs) or workflow.cooldownMs < 0 then
            problems[#problems + 1] = problem('cooldownMs', 'must be zero or more')
        end
    end

    if workflow.steps ~= nil then
        if type(workflow.steps) ~= 'table' then
            problems[#problems + 1] = problem('steps', 'must be a list')
        else
            for index, step in ipairs(workflow.steps) do
                validateStep(step, index, problems)
            end
        end
    end

    -- Consumption and reward are REQUESTS to whoever owns items and money. This
    -- resource records what was asked for and never grants anything itself.
    for _, field in ipairs({ 'consumes', 'rewards' }) do
        if workflow[field] ~= nil and type(workflow[field]) ~= 'table' then
            problems[#problems + 1] = problem(field, 'must be a list of requests')
        end
    end

    if workflow.capability ~= nil and type(workflow.capability) ~= 'string' then
        problems[#problems + 1] = problem('capability', 'must be a capability name')
    end

    if workflow.onComplete ~= nil and type(workflow.onComplete) ~= 'string' then
        problems[#problems + 1] = problem('onComplete', 'must be a server event name')
    end

    if #problems > 0 then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = problems }))
    end

    -- Accepted, with a note where the server cannot verify the outcome.
    local advisory = nil
    for _, step in ipairs(workflow.steps or {}) do
        if step.kind == Workflow.STEP.SKILL
            and (step.decidedBy or Workflow.DECIDED_BY.SERVER) == Workflow.DECIDED_BY.CLIENT then
            advisory = 'a skill check decided by the client is decided by the player: '
                    .. 'the minigame runs on their machine and reports its own result. '
                    .. "Use decidedBy = 'server' if the outcome matters"
            break
        end
    end

    return Nxc.Result.ok({ workflow = workflow, advisory = advisory })
end

--- Has enough time passed for this completion to be honest?
---
---@param workflow table
---@param elapsedMs number
---@return boolean
function Workflow.durationSatisfied(workflow, elapsedMs)
    if type(elapsedMs) ~= 'number' then return false end
    return elapsedMs >= (workflow.durationMs - Workflow.COMPLETION_TOLERANCE_MS)
end

NxcInteract.Workflow = Workflow
return Workflow
