-- Bridge is loaded from bridge/client.lua before this file
local CustomDoorStartIndex = #Config.Doors
local ManagerOpen          = false

-- ── State ─────────────────────────────────────────────────────────────────
local DoorStates    = {}   -- [index] bool
local FailAttempts  = {}   -- [index] count
local Lockouts      = {}   -- [index] ms timestamp
local AutoLockTimers= {}   -- [index] thread handle
local UIOpen        = false
local ActiveDoor    = nil
local LabelShowing  = false

-- ── Helpers ───────────────────────────────────────────────────────────────
local function IsLocked(i)
    return DoorStates[i] ~= false
end

local function Notify(cfg, ...)
    local desc = #({...}) > 0 and cfg.description:format(...) or cfg.description
    Bridge.Notify(desc, cfg.type, cfg.duration)
end

local function ApplyDoorState(door, locked)
    local hash = door.objHash or (door.objName ~= nil and door.objName ~= '' and GetHashKey(door.objName) or 0)
    if hash == 0 then return end
    local obj = GetClosestObjectOfType(
        door.objCoords.x, door.objCoords.y, door.objCoords.z,
        5.0, hash, false, false, false
    )
    if obj == 0 then return end
    FreezeEntityPosition(obj, locked)
end

-- ── Build door list for manager UI ────────────────────────────────────────
local function BuildDoorList()
    local list = {}
    for i, door in ipairs(Config.Doors) do
        local entry = {
            index    = i,
            name     = door.name,
            lockType = door.lockType or 'pin',
            isCustom = door.isCustom or false,
            customId = door.id,
            locked   = IsLocked(i),
        }
        -- Include full data for custom doors so manager can pre-fill edit form
        if door.isCustom then
            entry.x               = door.objCoords.x
            entry.y               = door.objCoords.y
            entry.z               = door.objCoords.z
            entry.heading         = door.heading
            entry.distance        = door.distance
            entry.objHash         = door.objHash
            entry.codes           = door.codes          or {}
            entry.authorizedJobs  = door.authorizedJobs  or {}
            entry.authorizedItems = door.authorizedItems or {}
        end
        list[#list + 1] = entry
    end
    return list
end

-- ── Auto-lock ─────────────────────────────────────────────────────────────
local function ScheduleAutoLock(doorIndex)
    local door = Config.Doors[doorIndex]
    if not door.autoLock or door.autoLock <= 0 then return end
    if AutoLockTimers[doorIndex] then return end -- already scheduled

    AutoLockTimers[doorIndex] = Citizen.CreateThread(function()
        Citizen.Wait(door.autoLock * 1000)
        if not IsLocked(doorIndex) then
            TriggerServerEvent('doorlock:toggleDoor', doorIndex, 'autolock')
        end
        AutoLockTimers[doorIndex] = nil
    end)
end

-- ── UI ────────────────────────────────────────────────────────────────────
local function OpenUI(doorIndex)
    local door = Config.Doors[doorIndex]
    if not door then return end
    local locked = IsLocked(doorIndex)

    -- Check lockout
    if Lockouts[doorIndex] and GetGameTimer() < Lockouts[doorIndex] then
        local rem = math.ceil((Lockouts[doorIndex] - GetGameTimer()) / 1000)
        Notify(Config.Notify.lockout, rem)
        return
    end

    UIOpen    = true
    ActiveDoor = doorIndex
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        door   = {
            index  = doorIndex,
            name   = door.name,
            locked = locked,
            color  = door.color  or '#F0B429',
            icon   = door.icon   or 'fa-solid fa-lock',
            maxLen = Config.MaxPinLength,
        }
    })
end

local function CloseUI()
    UIOpen     = false
    ActiveDoor = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

-- ── NUI Callbacks ─────────────────────────────────────────────────────────
RegisterNUICallback('close', function(data, cb)
    CloseUI()
    cb({})
end)

RegisterNUICallback('submitPin', function(data, cb)
    local doorIndex = tonumber(data.doorIndex)
    local pin       = tostring(data.pin or '')

    if not doorIndex or not Config.Doors[doorIndex] then cb({}); return end

    -- Lockout guard (extra client-side check)
    if Lockouts[doorIndex] and GetGameTimer() < Lockouts[doorIndex] then
        local rem = math.ceil((Lockouts[doorIndex] - GetGameTimer()) / 1000)
        Notify(Config.Notify.lockout, rem)
        cb({})
        return
    end

    TriggerServerEvent('doorlock:tryPin', doorIndex, pin)
    CloseUI()
    cb({})
end)

-- ── Server -> Client events ───────────────────────────────────────────────
RegisterNetEvent('doorlock:syncStates', function(states)
    DoorStates = states
end)

RegisterNetEvent('doorlock:updateState', function(doorIndex, isLocked)
    DoorStates[doorIndex] = isLocked
    local door = Config.Doors[doorIndex]
    if door then ApplyDoorState(door, isLocked) end

    -- Schedule auto-lock if door was just unlocked
    if not isLocked then
        ScheduleAutoLock(doorIndex)
    else
        AutoLockTimers[doorIndex] = nil
    end
end)

-- PIN result (success/fail flash)
RegisterNetEvent('doorlock:pinResult', function(doorIndex, success)
    if success then
        FailAttempts[doorIndex] = 0
        local locked = IsLocked(doorIndex)
        Notify(locked and Config.Notify.locked or Config.Notify.unlocked)
    else
        FailAttempts[doorIndex] = (FailAttempts[doorIndex] or 0) + 1
        if FailAttempts[doorIndex] >= Config.PinAttempts then
            Lockouts[doorIndex]     = GetGameTimer() + (Config.LockoutTime * 1000)
            FailAttempts[doorIndex] = 0
            Notify(Config.Notify.lockout, Config.LockoutTime)
        else
            Notify(Config.Notify.denied)
        end
    end
end)

-- ── Custom door sync ──────────────────────────────────────────────────────
RegisterNetEvent('doorlock:loadCustomDoors', function(customDoors)
    -- Unfreeze every custom door entity before removing it from the list.
    -- Without this, deleted doors stay physically frozen in the world.
    while #Config.Doors > CustomDoorStartIndex do
        local door = Config.Doors[#Config.Doors]
        ApplyDoorState(door, false)   -- unfreeze / unlock the prop
        DoorStates[#Config.Doors] = nil
        table.remove(Config.Doors)
    end
    for _, door in ipairs(customDoors) do
        table.insert(Config.Doors, {
            id              = door.id,
            name            = door.name,
            objHash         = door.objHash,
            objCoords       = vec3(door.x, door.y, door.z),
            heading         = door.heading,
            distance        = door.distance,
            locked          = door.isLocked,
            lockType        = door.lockType,
            codes           = door.codes,
            authorizedJobs  = door.authorizedJobs,
            authorizedItems = door.authorizedItems,
            isCustom        = true,
        })
        DoorStates[#Config.Doors] = door.isLocked
        -- Apply state immediately so doors don't flicker open on reload
        ApplyDoorState(Config.Doors[#Config.Doors], door.isLocked)
    end
    if ManagerOpen then
        SendNUIMessage({ action = 'manager:update', doors = BuildDoorList() })
    end
end)

-- ── Access methods ────────────────────────────────────────────────────────
local function TryJobAccess(doorIndex)
    local door  = Config.Doors[doorIndex]
    local bjob  = Bridge.GetPlayerJob()
    local job   = bjob and bjob.name  or ''
    local grade = bjob and bjob.grade or 0

    if door.authorizedJobs then
        for _, j in ipairs(door.authorizedJobs) do
            if j.name == job and grade >= j.grade then
                TriggerServerEvent('doorlock:toggleDoor', doorIndex, 'job')
                return true
            end
        end
    end
    Notify(Config.Notify.no_job)
    return false
end

local function TryItemAccess(doorIndex)
    local door = Config.Doors[doorIndex]
    if door.authorizedItems then
        for _, item in ipairs(door.authorizedItems) do
            if Bridge.HasItem(item) then
                TriggerServerEvent('doorlock:toggleDoor', doorIndex, 'item', item)
                return true
            end
        end
    end
    Notify(Config.Notify.no_item)
    return false
end

local function InteractDoor(doorIndex)
    local door     = Config.Doors[doorIndex]
    local lockType = door.lockType or 'pin'

    if lockType == 'pin' then
        OpenUI(doorIndex)

    elseif lockType == 'job' then
        TryJobAccess(doorIndex)

    elseif lockType == 'item' then
        TryItemAccess(doorIndex)

    elseif lockType == 'pin_or_job' then
        local bjob  = Bridge.GetPlayerJob()
        local job   = bjob and bjob.name  or ''
        local grade = bjob and bjob.grade or 0
        local hasJob = false
        if door.authorizedJobs then
            for _, j in ipairs(door.authorizedJobs) do
                if j.name == job and grade >= j.grade then hasJob = true; break end
            end
        end
        if hasJob then
            TriggerServerEvent('doorlock:toggleDoor', doorIndex, 'job')
        else
            OpenUI(doorIndex)
        end

    elseif lockType == 'any' then
        -- Priority: job > item > pin
        local bjob  = Bridge.GetPlayerJob()
        local job   = bjob and bjob.name  or ''
        local grade = bjob and bjob.grade or 0
        local hasJob = false
        if door.authorizedJobs then
            for _, j in ipairs(door.authorizedJobs) do
                if j.name == job and grade >= j.grade then hasJob = true; break end
            end
        end
        if hasJob then
            TriggerServerEvent('doorlock:toggleDoor', doorIndex, 'job')
            return
        end
        if door.authorizedItems then
            for _, item in ipairs(door.authorizedItems) do
                if Bridge.HasItem(item) then
                    TriggerServerEvent('doorlock:toggleDoor', doorIndex, 'item', item)
                    return
                end
            end
        end
        OpenUI(doorIndex)
    end
end

-- ── Door Manager command ───────────────────────────────────────────────────
RegisterCommand('doormanager', function()
    ManagerOpen = true
    UIOpen      = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'manager:open', doors = BuildDoorList() })
end, false)

-- ── Manager NUI callbacks ──────────────────────────────────────────────────
RegisterNUICallback('manager:close', function(_, cb)
    ManagerOpen = false
    UIOpen      = false
    SetNuiFocus(false, false)
    cb({})
end)

RegisterNUICallback('manager:detectDoor', function(data, cb)
    local slot = (type(data) == 'table' and data.slot) or 'a'
    cb({})
    Citizen.CreateThread(function()
        Citizen.Wait(100)
        local ped       = PlayerPedId()
        local pos       = GetEntityCoords(ped)
        local camCoords = GetGameplayCamCoord()
        local camRot    = GetGameplayCamRot(2)
        local rz        = math.rad(camRot.z)
        local rx        = math.rad(camRot.x)
        local nrm       = math.abs(math.cos(rx))
        local dir       = vector3(-math.sin(rz) * nrm, math.cos(rz) * nrm, math.sin(rx))

        -- Primary: camera ray (flags 287 = all entity types including objects/props)
        local dest = camCoords + dir * 10.0
        local ray  = StartShapeTestRay(camCoords.x, camCoords.y, camCoords.z,
                                       dest.x, dest.y, dest.z, 287, ped, 0)
        Citizen.Wait(0)
        local _, hit, _, _, entity = GetShapeTestResult(ray)

        -- Fallback: short ray from player torso forward (catches doors player faces)
        if hit ~= 1 or entity == 0 or IsPedAPlayer(entity) then
            local fwd  = GetEntityForwardVector(ped)
            local dest2 = vector3(pos.x + fwd.x * 3.0, pos.y + fwd.y * 3.0, pos.z + 0.6)
            local ray2  = StartShapeTestRay(pos.x, pos.y, pos.z + 0.6,
                                            dest2.x, dest2.y, dest2.z, 287, ped, 0)
            Citizen.Wait(0)
            local _, hit2, _, _, ent2 = GetShapeTestResult(ray2)
            if hit2 == 1 and ent2 ~= 0 and not IsPedAPlayer(ent2) then
                hit    = hit2
                entity = ent2
            end
        end

        local result = {
            detected = false,
            x = math.floor(pos.x * 100) / 100,
            y = math.floor(pos.y * 100) / 100,
            z = math.floor(pos.z * 100) / 100,
            heading = math.floor(GetEntityHeading(ped) * 10) / 10,
            hash = 0,
        }
        if hit == 1 and entity ~= 0 and not IsPedAPlayer(entity) and DoesEntityExist(entity) then
            local oc = GetEntityCoords(entity)
            result.detected = true
            result.x        = math.floor(oc.x * 100) / 100
            result.y        = math.floor(oc.y * 100) / 100
            result.z        = math.floor(oc.z * 100) / 100
            result.heading  = math.floor(GetEntityHeading(entity) * 10) / 10
            result.hash     = GetEntityModel(entity)
        end
        SendNUIMessage({ action = 'manager:detectResult', slot = slot, data = result })
    end)
end)

RegisterNUICallback('manager:saveDoor', function(data, cb)
    TriggerServerEvent('doorlock:manager:addDoor', data)
    cb({})
end)

RegisterNUICallback('manager:editDoor', function(data, cb)
    TriggerServerEvent('doorlock:manager:editDoor', data)
    cb({})
end)

RegisterNUICallback('manager:deleteDoor', function(data, cb)
    TriggerServerEvent('doorlock:manager:deleteDoor', data.customId)
    cb({})
end)

-- ── Admin force-toggle ────────────────────────────────────────────────────
RegisterNetEvent('doorlock:adminToggle', function()
    local pos = GetEntityCoords(PlayerPedId())
    local best, bestDist = nil, 999
    for i, door in ipairs(Config.Doors) do
        local d = #(pos - door.objCoords)
        if d < bestDist then bestDist = d; best = i end
    end
    if best then
        TriggerServerEvent('doorlock:toggleDoor', best, 'admin')
    end
end)

-- ── Double-door pointer selection ─────────────────────────────────────────
RegisterNUICallback('manager:startDoorSelect', function(data, cb)
    cb({})
    SetNuiFocus(false, false)

    Citizen.CreateThread(function()
        local selectA = nil
        local phase   = 1
        SendNUIMessage({ action = 'manager:selectPhase', phase = 1 })

        while phase <= 2 do
            Citizen.Wait(0)

            if IsControlJustReleased(0, Config.InteractKey) then
                local ped       = PlayerPedId()
                local pos       = GetEntityCoords(ped)
                local camCoords = GetGameplayCamCoord()
                local camRot    = GetGameplayCamRot(2)
                local rz        = math.rad(camRot.z)
                local rx        = math.rad(camRot.x)
                local nrm       = math.abs(math.cos(rx))
                local dir       = vector3(-math.sin(rz) * nrm, math.cos(rz) * nrm, math.sin(rx))
                local dest      = camCoords + dir * 10.0
                local ray       = StartShapeTestRay(
                    camCoords.x, camCoords.y, camCoords.z,
                    dest.x, dest.y, dest.z, 287, ped, 0
                )
                Citizen.Wait(0)
                local _, hit, _, _, entity = GetShapeTestResult(ray)

                local result = {
                    detected = false,
                    x        = math.floor(pos.x * 100) / 100,
                    y        = math.floor(pos.y * 100) / 100,
                    z        = math.floor(pos.z * 100) / 100,
                    heading  = math.floor(GetEntityHeading(ped) * 10) / 10,
                    hash     = 0,
                }

                if hit == 1 and entity ~= 0 and not IsPedAPlayer(entity) and DoesEntityExist(entity) then
                    local oc        = GetEntityCoords(entity)
                    result.detected = true
                    result.x        = math.floor(oc.x * 100) / 100
                    result.y        = math.floor(oc.y * 100) / 100
                    result.z        = math.floor(oc.z * 100) / 100
                    result.heading  = math.floor(GetEntityHeading(entity) * 10) / 10
                    result.hash     = GetEntityModel(entity)
                end

                if phase == 1 then
                    selectA = result
                    phase   = 2
                    SendNUIMessage({ action = 'manager:selectPhase', phase = 2 })
                else
                    phase = 3  -- exit loop
                    SetNuiFocus(true, true)
                    SendNUIMessage({
                        action = 'manager:selectResult',
                        doorA  = selectA,
                        doorB  = result,
                    })
                end
            end
        end
    end)
end)

-- ── Main proximity loop ───────────────────────────────────────────────────
Citizen.CreateThread(function()
    while true do
        local sleep     = 500
        local ped       = PlayerPedId()
        local pos       = GetEntityCoords(ped)
        local nearDoor  = nil
        local nearDist  = Config.DrawDistance + 1.0

        for i, door in ipairs(Config.Doors) do
            local dist = #(pos - door.objCoords)

            -- Apply state when close
            if dist < (door.distance or 1.5) + 6.0 then
                ApplyDoorState(door, IsLocked(i))
            end

            -- Track closest in label range
            if dist < Config.DrawDistance and dist < nearDist then
                nearDist = dist
                nearDoor = i
            end
        end

        -- Show / hide label for closest door
        if nearDoor and not UIOpen then
            sleep = 0
            local door     = Config.Doors[nearDoor]
            local locked   = IsLocked(nearDoor)
            local lockStr  = locked and '[LOCKED]' or '[UNLOCKED]'
            local labelText = ('[E] %s - %s'):format(door.name, lockStr)
            SetTextFont(4)
            SetTextProportional(1)
            SetTextScale(0.45, 0.45)
            SetTextColour(255, 255, 255, 215)
            SetTextDropShadow(0, 0, 0, 0, 150)
            SetTextEdge(2, 0, 0, 0, 150)
            SetTextDropShadow()
            SetTextOutline()
            SetTextEntry('STRING')
            AddTextComponentString(labelText)
            DrawText(0.5, 0.02)
            LabelShowing = true

            if IsControlJustReleased(0, Config.InteractKey) then
                LabelShowing = false
                InteractDoor(nearDoor)
            end
        elseif LabelShowing then
            LabelShowing = false
        end

        Citizen.Wait(sleep)
    end
end)

-- ── Initial sync ──────────────────────────────────────────────────────────
Citizen.CreateThread(function()
    Citizen.Wait(2000)
    TriggerServerEvent('doorlock:requestSync')
end)
