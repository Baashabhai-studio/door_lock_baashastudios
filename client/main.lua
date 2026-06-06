-- Bridge is loaded from bridge/client.lua before this file
local CustomDoorStartIndex = #Config.Doors
local ManagerOpen          = false

-- ── State ─────────────────────────────────────────────────────────────────
local DoorStates      = {}   -- [index] bool
local FailAttempts    = {}   -- [index] count
local Lockouts        = {}   -- [index] ms timestamp
local AutoLockTimers  = {}   -- [index] thread handle
local DoorEntityCache = {}   -- [index] entity handle — avoids repeated pool scans
local DoorSystemKeys  = {}   -- [index] string key — tracks doors registered with GTA door system
local UIOpen          = false
local ActiveDoor      = nil
local LabelShowing    = false
local OutlinedEntity  = 0    -- entity currently highlighted during detection

-- ── Helpers ───────────────────────────────────────────────────────────────
local function IsLocked(i)
    return DoorStates[i] ~= false
end

local function Notify(cfg, ...)
    local desc = #({...}) > 0 and cfg.description:format(...) or cfg.description
    Bridge.Notify(desc, cfg.type, cfg.duration)
end

-- Apply lock/unlock to a door entity.
-- Guille-style: find the entity by hash near saved coords, freeze it in place,
-- reset its heading. No position snapping — the entity stays where it was placed.
-- For slide type: use GTA's door system (works for native auto-doors; a no-op for
-- custom props, which just stay frozen by the normal path below if also using normal).
local function ApplyDoorState(door, locked, doorIndex)
    local hash = door.objHash or (door.objName ~= nil and door.objName ~= '' and GetHashKey(door.objName) or 0)
    if hash == 0 then return end

    local x, y, z = door.objCoords.x, door.objCoords.y, door.objCoords.z

    -- ── Slide path: GTA door system ──────────────────────────────────────────
    if door.moveType == 'slide' then
        local key = DoorSystemKeys[doorIndex] or ('doorlock_' .. tostring(hash) .. '_' .. tostring(doorIndex or 0))
        if doorIndex then DoorSystemKeys[doorIndex] = key end
        if not IsDoorRegisteredWithSystem(key) then
            AddDoorToSystem(key, hash, door.objCoords, false, false, false)
        end
        if locked then
            DoorSystemSetAutomaticDistance(key, 0.0,  false, false)
            DoorSystemSetDoorState(key,        4,     false, false)
        else
            DoorSystemSetDoorState(key,        0,     false, false)
            DoorSystemSetAutomaticDistance(key, 30.0, false, false)
        end
        return
    end

    -- ── Normal path: find entity, freeze in place ────────────────────────────
    -- Cache check first (avoids per-frame hash lookup)
    local obj = doorIndex and DoorEntityCache[doorIndex]
    if not obj or obj == 0 or not DoesEntityExist(obj) then
        -- 5 m radius — tight enough to avoid the wrong prop but forgiving for MLO
        obj = GetClosestObjectOfType(x, y, z, 5.0, hash, false, false, false)
    end

    -- Pool scan fallback for MLO / YMap props that GetClosestObjectOfType misses.
    -- Filtered by model hash to avoid accidentally grabbing a nearby vehicle or wall.
    if not obj or obj == 0 then
        local bestDist = 5.0
        for _, candidate in ipairs(GetGamePool('CObject')) do
            if DoesEntityExist(candidate) and GetEntityModel(candidate) == hash then
                local d = #(door.objCoords - GetEntityCoords(candidate))
                if d < bestDist then bestDist = d; obj = candidate end
            end
        end
    end

    if obj and obj ~= 0 then
        if doorIndex then DoorEntityCache[doorIndex] = obj end
        if locked then
            FreezeEntityPosition(obj, true)
            SetEntityHeading(obj, door.heading or GetEntityHeading(obj))
        else
            FreezeEntityPosition(obj, false)
        end
        return
    end

    -- Last resort: GTA native door-state API (vanilla interiors)
    SetStateOfClosestDoorOfType(hash, x, y, z, locked, door.heading or 0.0)
end

-- Remove a door from the GTA door system when it is deleted/unloaded
local function CleanupDoorSystem(doorIndex)
    local key = DoorSystemKeys[doorIndex]
    if key and IsDoorRegisteredWithSystem(key) then
        RemoveDoorFromSystem(key)
    end
    DoorSystemKeys[doorIndex]  = nil
    DoorEntityCache[doorIndex] = nil
end

-- ── Build door list for manager UI ────────────────────────────────────────
local function BuildDoorList()
    local list = {}
    for i, door in ipairs(Config.Doors) do
        -- Skip secondary doors in a double-door group (where groupId != id).
        -- Only the primary door (id == groupId) appears in the list; toggling it
        -- propagates to the secondary via ApplyLinkedDoors on the server.
        if door.isCustom and door.groupId and door.id and door.groupId ~= door.id then
            goto continue
        end
        local entry = {
            index    = i,
            name     = door.name,
            lockType = door.lockType or 'pin',
            isCustom = door.isCustom or false,
            customId = door.id,
            locked   = IsLocked(i),
            isDouble = (door.linkedDoors ~= nil and #door.linkedDoors > 0),
        }
        -- Include full data for custom doors so manager can pre-fill edit form
        if door.isCustom then
            entry.x               = door.objCoords.x
            entry.y               = door.objCoords.y
            entry.z               = door.objCoords.z
            entry.heading         = door.heading
            entry.distance        = door.distance
            entry.objHash         = door.objHash
            entry.moveType        = door.moveType        or 'normal'
            entry.codes           = door.codes          or {}
            entry.authorizedJobs  = door.authorizedJobs  or {}
            entry.authorizedItems = door.authorizedItems or {}
        end
        list[#list + 1] = entry
        ::continue::
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
    if door then ApplyDoorState(door, isLocked, doorIndex) end

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
        local idx  = #Config.Doors
        local door = Config.Doors[idx]
        -- Restore the entity to its saved (closed) position before unfreezing.
        -- If a previous bug moved the entity to the wrong world position, this
        -- moves it back so the prop doesn't stay stuck in the wrong spot.
        local restoreObj = DoorEntityCache[idx]
        if restoreObj and restoreObj ~= 0 and DoesEntityExist(restoreObj) then
            SetEntityCoords(restoreObj, door.objCoords.x, door.objCoords.y, door.objCoords.z, false, false, false, false)
            SetEntityHeading(restoreObj, door.heading or GetEntityHeading(restoreObj))
            FreezeEntityPosition(restoreObj, false)
        else
            ApplyDoorState(door, false, idx)
        end
        DoorStates[idx] = nil
        CleanupDoorSystem(idx)
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
            moveType        = door.moveType or 'normal',
            codes           = door.codes,
            authorizedJobs  = door.authorizedJobs,
            authorizedItems = door.authorizedItems,
            groupId         = door.groupId,
            isCustom        = true,
        })
        local newIdx = #Config.Doors
        DoorStates[newIdx] = door.isLocked
        -- Apply state immediately so doors don't flicker open on reload
        ApplyDoorState(Config.Doors[newIdx], door.isLocked, newIdx)
    end

    -- Resolve groupId into linkedDoors so double doors stay in sync on this client
    local groups = {}
    for idx = CustomDoorStartIndex + 1, #Config.Doors do
        local g = Config.Doors[idx].groupId
        if g then
            if not groups[g] then groups[g] = {} end
            table.insert(groups[g], idx)
        end
    end
    for _, indices in pairs(groups) do
        if #indices > 1 then
            for _, idx in ipairs(indices) do
                local linked = {}
                for _, other in ipairs(indices) do
                    if other ~= idx then table.insert(linked, other) end
                end
                Config.Doors[idx].linkedDoors = linked
            end
        end
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
    if OutlinedEntity ~= 0 then
        SetEntityDrawOutline(OutlinedEntity, false)
        OutlinedEntity = 0
    end
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
        local fwd       = GetEntityForwardVector(ped)

        local entity = 0

        -- flag -1 = all entity types (matches guille's approach; catches more props)
        -- Ray 1: camera direction, 20 units
        local r1 = StartShapeTestRay(camCoords.x, camCoords.y, camCoords.z,
            camCoords.x + dir.x * 20.0, camCoords.y + dir.y * 20.0, camCoords.z + dir.z * 20.0,
            -1, ped, 0)
        Citizen.Wait(0)
        local _, h1, _, _, e1 = GetShapeTestResult(r1)
        if h1 == 1 and e1 ~= 0 and IsEntityAnObject(e1) and DoesEntityExist(e1) then
            entity = e1
        end

        -- Ray 2: player forward at waist height
        if entity == 0 then
            local r2 = StartShapeTestRay(pos.x, pos.y, pos.z + 0.6,
                pos.x + fwd.x * 4.0, pos.y + fwd.y * 4.0, pos.z + 0.6,
                -1, ped, 0)
            Citizen.Wait(0)
            local _, h2, _, _, e2 = GetShapeTestResult(r2)
            if h2 == 1 and e2 ~= 0 and IsEntityAnObject(e2) and DoesEntityExist(e2) then
                entity = e2
            end
        end

        -- Ray 3: angled upward-forward (catches overhead/tilt-up garage doors)
        if entity == 0 then
            local r3 = StartShapeTestRay(pos.x, pos.y, pos.z + 0.8,
                pos.x + fwd.x * 3.0, pos.y + fwd.y * 3.0, pos.z + 3.5,
                -1, ped, 0)
            Citizen.Wait(0)
            local _, h3, _, _, e3 = GetShapeTestResult(r3)
            if h3 == 1 and e3 ~= 0 and IsEntityAnObject(e3) and DoesEntityExist(e3) then
                entity = e3
            end
        end

        -- Final fallback: entity pool scan for MLO/YMap props rays miss
        if entity == 0 then
            local closestDist = 6.0
            for _, obj in ipairs(GetGamePool('CObject')) do
                if DoesEntityExist(obj) and IsEntityAnObject(obj) then
                    local d = #(pos - GetEntityCoords(obj))
                    if d < closestDist then
                        closestDist = d
                        entity      = obj
                    end
                end
            end
        end

        -- Outline the detected prop so the admin can see exactly what was found
        if OutlinedEntity ~= 0 then SetEntityDrawOutline(OutlinedEntity, false) end
        OutlinedEntity = entity
        if entity ~= 0 then SetEntityDrawOutline(entity, true) end

        -- Save the entity's OWN coords and heading.
        -- Important: scan the door while it is in its CLOSED/resting position.
        -- These saved coords are where GetClosestObjectOfType will search and where
        -- FreezeEntityPosition locks the entity. Wrong position when scanned = wrong
        -- position when locked.
        local result = {
            detected = false,
            x       = math.floor(pos.x * 100) / 100,
            y       = math.floor(pos.y * 100) / 100,
            z       = math.floor(pos.z * 100) / 100,
            heading = math.floor(GetEntityHeading(ped) * 10) / 10,
            hash    = 0,
        }
        if entity ~= 0 and IsEntityAnObject(entity) and DoesEntityExist(entity) then
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
                local dest      = camCoords + dir * 20.0
                local ray       = StartShapeTestRay(
                    camCoords.x, camCoords.y, camCoords.z,
                    dest.x, dest.y, dest.z, -1, ped, 0
                )
                Citizen.Wait(0)
                local _, hit, _, _, entity = GetShapeTestResult(ray)

                -- Outline the selected prop for visual confirmation
                if OutlinedEntity ~= 0 then SetEntityDrawOutline(OutlinedEntity, false) end
                OutlinedEntity = (hit == 1 and entity ~= 0 and IsEntityAnObject(entity)) and entity or 0
                if OutlinedEntity ~= 0 then SetEntityDrawOutline(OutlinedEntity, true) end

                local result = {
                    detected = false,
                    x        = math.floor(pos.x * 100) / 100,
                    y        = math.floor(pos.y * 100) / 100,
                    z        = math.floor(pos.z * 100) / 100,
                    heading  = math.floor(GetEntityHeading(ped) * 10) / 10,
                    hash     = 0,
                }

                if hit == 1 and entity ~= 0 and IsEntityAnObject(entity) and DoesEntityExist(entity) then
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
        local sleep    = 500
        local ped      = PlayerPedId()
        local pos      = GetEntityCoords(ped)
        local nearDoor = nil
        local nearDist = math.huge

        for i, door in ipairs(Config.Doors) do
            local dist     = #(pos - door.objCoords)
            -- Per-door interact range — used for BOTH state application and label.
            -- Applying from 30 m (like guille_doorlock) ensures the door is frozen
            -- before GTA's own auto-open system kicks in (~5-8 m), preventing the
            -- "locked but stuck open" bug.
            local doorDist = door.distance or 1.5

            -- Apply lock state from 30 m so GTA can't open the door before we freeze it
            if dist < 30.0 then
                ApplyDoorState(door, IsLocked(i), i)
            end

            -- Label / interaction range = doorDist from the door centre in any
            -- direction — this makes detection symmetric from both sides of the door.
            if dist < doorDist and dist < nearDist then
                nearDist = dist
                nearDoor = i
            end
        end

        -- Show / hide label for closest door
        if nearDoor and not UIOpen then
            sleep = 0  -- render every frame while label is on screen
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
