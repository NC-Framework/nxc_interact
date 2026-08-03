--- The client half: playing the steps, and letting the player out.
---
--- **NOTHING HERE IS TRUSTED.** It plays an animation, holds a prop, shows a
--- bar, and reports that it stopped. The server decides whether that counts,
--- measured against the start it recorded — so a player who deletes this file
--- entirely still waits the full duration.
---
--- Which frees this code to be simple. It has no security to enforce, only an
--- experience to deliver and a promise to keep: **the player can always get
--- out.**

if IsDuplicityVersion() then return end

local Runtime = {}

local active = nil

--- Undo everything a workflow did to the player.
---
--- Called on every exit: finished, cancelled, died, refused, or the resource
--- stopping. Never fails and never refuses — the residue of a missed cleanup is
--- a player stuck in an animation holding an invisible object, and that is a
--- reconnect.
local function cleanup()
    local ped = PlayerPedId()

    ClearPedTasks(ped)

    if active and active.props then
        for _, prop in ipairs(active.props) do
            if DoesEntityExist(prop) then DeleteEntity(prop) end
        end
    end

    if GetResourceState('nxc_ui') == 'started' then
        pcall(function() exports.nxc_ui:close() end)
    end

    active = nil
end

local function playAnimation(step)
    local ped = PlayerPedId()

    RequestAnimDict(step.dict)
    local deadline = GetGameTimer() + 2000
    while not HasAnimDictLoaded(step.dict) and GetGameTimer() < deadline do
        Wait(10)
    end

    -- A dictionary that never loads is not a reason to abandon the workflow. The
    -- wait is the thing being enforced; the animation is decoration, and a
    -- missing one should cost appearance rather than the action.
    if not HasAnimDictLoaded(step.dict) then
        Nxc.Logger.warn('interact.anim_dict_unavailable', { dict = step.dict })
        return
    end

    TaskPlayAnim(ped, step.dict, step.anim, 4.0, -4.0, -1, step.flags or 49, 0, false, false, false)
end

local function attachProp(step)
    local ped = PlayerPedId()

    RequestModel(step.model)
    local deadline = GetGameTimer() + 2000
    while not HasModelLoaded(step.model) and GetGameTimer() < deadline do Wait(10) end
    if not HasModelLoaded(step.model) then
        Nxc.Logger.warn('interact.prop_unavailable', { model = tostring(step.model) })
        return
    end

    local coords = GetEntityCoords(ped)
    local prop = CreateObject(step.model, coords.x, coords.y, coords.z, true, true, false)
    AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, step.bone),
        step.offset and step.offset.x or 0.0,
        step.offset and step.offset.y or 0.0,
        step.offset and step.offset.z or 0.0,
        step.rotation and step.rotation.x or 0.0,
        step.rotation and step.rotation.y or 0.0,
        step.rotation and step.rotation.z or 0.0,
        true, true, false, true, 1, true)

    SetModelAsNoLongerNeeded(step.model)
    active.props[#active.props + 1] = prop
end

--- Run a workflow the server has authorised.
---
---@param instruction table  { key, durationMs, steps, correlationId }
function Runtime.begin(instruction)
    if active then
        -- The server already refuses a second start, so reaching here means the
        -- two disagree. Cleaning up first is the safe reading.
        cleanup()
    end

    active = {
        key = instruction.key,
        props = {},
        startedAtMs = GetGameTimer(),
        durationMs = instruction.durationMs,
        cancelled = false,
    }

    local progressLabel = nil
    for _, step in ipairs(instruction.steps or {}) do
        if step.kind == NxcInteract.Workflow.STEP.ANIMATION then
            playAnimation(step)
        elseif step.kind == NxcInteract.Workflow.STEP.PROP then
            attachProp(step)
        elseif step.kind == NxcInteract.Workflow.STEP.PROGRESS then
            progressLabel = step.label
        end
    end

    if progressLabel and GetResourceState('nxc_ui') == 'started' then
        pcall(function()
            exports.nxc_ui:show({
                type = 'progress', surface = 'nxc_interact',
                label = progressLabel, durationMs = instruction.durationMs,
            })
        end)
    end

    CreateThread(function()
        local this = active

        while active == this and not this.cancelled do
            local elapsed = GetGameTimer() - this.startedAtMs
            if elapsed >= this.durationMs then break end

            -- The ways out. Every one of them is a cancellation rather than a
            -- failure: a player who walked away did not fail the action, they
            -- declined it, and the server sets no cooldown for a cancellation.
            if IsControlJustReleased(0, 202) then this.cancelled = true break end
            if IsPedFatallyInjured(PlayerPedId()) then this.cancelled = true break end

            Wait(50)
        end

        if active ~= this then return end  -- superseded or already cleaned up

        local cancelled = this.cancelled
        cleanup()

        if cancelled then
            TriggerServerEvent('nxc_interact:server:cancel')
            return
        end

        -- Reports that it stopped. NOT how long it took, and not whether it
        -- should count — the server has both and believes neither from here.
        TriggerServerEvent('nxc_interact:server:complete', { key = this.key })
    end)
end

RegisterNetEvent('nxc_interact:client:begin', function(instruction)
    if type(instruction) ~= 'table' then return end
    Runtime.begin(instruction)
end)

RegisterNetEvent('nxc_interact:client:refused', function(_, reason)
    cleanup()

    -- A refusal a player cannot see is a feature that silently does nothing. The
    -- reason is deliberately vague to the player and precise in the log: they do
    -- not need to know which check failed, and telling them would help someone
    -- probe it.
    if GetResourceState('nxc_ui') == 'started' then
        pcall(function()
            exports.nxc_ui:show({
                type = 'notify', surface = 'nxc_interact',
                text = 'You cannot do that right now.',
                severity = 'warning', durationMs = 3000,
            })
        end)
    end
    Nxc.Logger.debug('interact.refused', { reason = tostring(reason) })
end)

RegisterNetEvent('nxc_interact:client:finished', function(_, success)
    cleanup()
    if success == false and GetResourceState('nxc_ui') == 'started' then
        pcall(function()
            exports.nxc_ui:show({
                type = 'notify', surface = 'nxc_interact',
                text = 'That did not work.', severity = 'warning', durationMs = 3000,
            })
        end)
    end
end)

--- The resource stopping must not leave a player in an animation it started.
AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then cleanup() end
end)

exports('isBusy', function() return active ~= nil end)

exports('cancel', function()
    if active then active.cancelled = true end
end)

NxcInteract.Runtime = Runtime
return Runtime
