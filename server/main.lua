-- Bridge is loaded from bridge/server.lua before this file
local DoorStates           = {}
local CustomDoors          = {}
local CustomDoorStartIndex = #Config.Doors

-- ── Database init ─────────────────────────────────────────────────────────
local function InitStates()
    if not Config.UseDatabase then
        for i, door in ipairs(Config.Doors) do
            DoorStates[i] = door.locked
        end
        return
    end

    MySQL.query([[
        CREATE TABLE IF NOT EXISTS `door_lock_custom` (
            `id`               INT AUTO_INCREMENT NOT NULL,
            `name`             VARCHAR(100) NOT NULL,
            `obj_hash`         BIGINT NOT NULL DEFAULT 0,
            `coords_x`         FLOAT NOT NULL,
            `coords_y`         FLOAT NOT NULL,
            `coords_z`         FLOAT NOT NULL,
            `heading`          FLOAT NOT NULL DEFAULT 0.0,
            `distance`         FLOAT NOT NULL DEFAULT 1.5,
            `lock_type`        VARCHAR(20) NOT NULL DEFAULT 'pin',
            `codes`            TEXT,
            `authorized_jobs`  TEXT,
            `authorized_items` TEXT,
            `group_id`         INT NULL,
            `is_locked`        TINYINT(1) NOT NULL DEFAULT 1,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
    -- Migration: add new columns for existing installs
    MySQL.query([[ALTER TABLE door_lock_custom ADD COLUMN IF NOT EXISTS authorized_jobs  TEXT]])
    MySQL.query([[ALTER TABLE door_lock_custom ADD COLUMN IF NOT EXISTS authorized_items TEXT]])
    MySQL.query([[ALTER TABLE door_lock_custom ADD COLUMN IF NOT EXISTS group_id         INT NULL]])

    MySQL.query([[
        CREATE TABLE IF NOT EXISTS `door_lock_baashastudios` (
            `door_index` INT          NOT NULL,
            `is_locked`  TINYINT(1)   NOT NULL DEFAULT 1,
            `updated_at` TIMESTAMP    DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`door_index`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    MySQL.query('SELECT door_index, is_locked FROM door_lock_baashastudios', function(rows)
        local saved = {}
        for _, row in ipairs(rows) do
            saved[row.door_index] = row.is_locked == 1
        end
        for i, door in ipairs(Config.Doors) do
            DoorStates[i] = (saved[i] ~= nil) and saved[i] or door.locked
        end
        print(('[^2door_lock_baashastudios^7] Loaded %d door states.'):format(#Config.Doors))
    end)
end

-- ── Load / rebuild custom doors from DB ────────────────────────────────────
local function LoadAndBroadcastCustomDoors()
    if not Config.UseDatabase then return end
    MySQL.query('SELECT * FROM door_lock_custom ORDER BY id ASC', function(rows)
        -- Prune custom doors from Config.Doors
        while #Config.Doors > CustomDoorStartIndex do
            DoorStates[#Config.Doors] = nil
            table.remove(Config.Doors)
        end
        CustomDoors = {}

        -- First pass: build all custom door entries
        for _, row in ipairs(rows) do
            local d = {
                id              = row.id,
                name            = row.name,
                objHash         = row.obj_hash,
                objCoords       = vec3(row.coords_x, row.coords_y, row.coords_z),
                heading         = row.heading,
                distance        = row.distance,
                locked          = row.is_locked == 1,
                lockType        = row.lock_type,
                codes           = row.codes           and json.decode(row.codes)           or {},
                authorizedJobs  = row.authorized_jobs  and json.decode(row.authorized_jobs)  or nil,
                authorizedItems = row.authorized_items and json.decode(row.authorized_items) or nil,
                groupId         = row.group_id,
                isCustom        = true,
            }
            table.insert(Config.Doors, d)
            DoorStates[#Config.Doors] = d.locked
            table.insert(CustomDoors, {
                id              = row.id,
                name            = row.name,
                objHash         = row.obj_hash,
                x               = row.coords_x,
                y               = row.coords_y,
                z               = row.coords_z,
                heading         = row.heading,
                distance        = row.distance,
                lockType        = row.lock_type,
                codes           = row.codes           and json.decode(row.codes)           or {},
                authorizedJobs  = row.authorized_jobs  and json.decode(row.authorized_jobs)  or nil,
                authorizedItems = row.authorized_items and json.decode(row.authorized_items) or nil,
                isLocked        = row.is_locked == 1,
            })
        end

        -- Second pass: resolve group_id into linkedDoors
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

        TriggerClientEvent('doorlock:loadCustomDoors', -1, CustomDoors)
        print(('[^2door_lock_baashastudios^7] Custom doors loaded: %d'):format(#CustomDoors))
    end)
end

local function PersistState(doorIndex)
    if not Config.UseDatabase then return end
    local val = DoorStates[doorIndex] and 1 or 0
    MySQL.update(
        'INSERT INTO door_lock_baashastudios (door_index, is_locked) VALUES (?, ?) ON DUPLICATE KEY UPDATE is_locked = ?',
        { doorIndex, val, val }
    )
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    Citizen.Wait(500)
    InitStates()
    Citizen.Wait(800)
    LoadAndBroadcastCustomDoors()
end)

-- ── Broadcast helpers ─────────────────────────────────────────────────────
local function BroadcastState(doorIndex)
    TriggerClientEvent('doorlock:updateState', -1, doorIndex, DoorStates[doorIndex])
end

-- ── Linked door sync (double doors, paired gates, etc.) ───────────────────
local function ApplyLinkedDoors(doorIndex)
    local door = Config.Doors[doorIndex]
    if not door or not door.linkedDoors then return end
    for _, linkedIdx in ipairs(door.linkedDoors) do
        if Config.Doors[linkedIdx] then
            DoorStates[linkedIdx] = DoorStates[doorIndex]
            PersistState(linkedIdx)
            BroadcastState(linkedIdx)
        end
    end
end

-- ── Sync request (on player join) ─────────────────────────────────────────
RegisterNetEvent('doorlock:requestSync', function()
    TriggerClientEvent('doorlock:syncStates', source, DoorStates)
    TriggerClientEvent('doorlock:loadCustomDoors', source, CustomDoors)
end)

-- ── PIN validation (server-side — never expose codes to client) ───────────
RegisterNetEvent('doorlock:tryPin', function(doorIndex, pin)
    local src  = source
    local door = Config.Doors[doorIndex]
    if not door then return end

    -- Validate input type
    if type(pin) ~= 'string' or #pin < 1 or #pin > Config.MaxPinLength then
        TriggerClientEvent('doorlock:pinResult', src, doorIndex, false)
        return
    end

    if not door.codes or #door.codes == 0 then
        TriggerClientEvent('doorlock:pinResult', src, doorIndex, false)
        return
    end

    for _, code in ipairs(door.codes) do
        if tostring(code) == pin then
            -- Toggle
            DoorStates[doorIndex] = not DoorStates[doorIndex]
            PersistState(doorIndex)
            BroadcastState(doorIndex)
            ApplyLinkedDoors(doorIndex)
            TriggerClientEvent('doorlock:pinResult', src, doorIndex, true)
            print(('[^2door_lock_baashastudios^7] Player %d toggled door #%d via PIN. Locked: %s'):format(
                src, doorIndex, tostring(DoorStates[doorIndex])
            ))
            return
        end
    end

    -- Wrong PIN
    TriggerClientEvent('doorlock:pinResult', src, doorIndex, false)
end)

-- ── Job / Item / Admin toggle ─────────────────────────────────────────────
RegisterNetEvent('doorlock:toggleDoor', function(doorIndex, method, itemName)
    local src  = source
    local door = Config.Doors[doorIndex]
    if not door or not Bridge.PlayerExists(src) then return end

    -- Server-side job validation
    if method == 'job' then
        local job   = Bridge.GetPlayerJob(src)
        local valid = false
        if job and door.authorizedJobs then
            for _, j in ipairs(door.authorizedJobs) do
                if j.name == job.name and job.grade >= j.grade then
                    valid = true; break
                end
            end
        end
        if not valid then
            print(('[^1door_lock_baashastudios^7] Player %d attempted job bypass on door #%d without auth!'):format(src, doorIndex))
            return
        end

    -- Server-side item validation
    elseif method == 'item' then
        local valid = false
        if door.authorizedItems and itemName then
            for _, item in ipairs(door.authorizedItems) do
                if item == itemName then valid = true; break end
            end
        end
        if not valid then return end

        -- Consume item if configured
        if door.consumeItem and itemName then
            Bridge.RemoveItem(src, itemName, 1)
            Bridge.Notify(src, Config.Notify.consumed.description, 'primary', 3000)
        end

    elseif method == 'autolock' then
        -- Only re-lock (do not toggle if already locked)
        if DoorStates[doorIndex] then return end

    elseif method == 'admin' then
        if not Bridge.HasPermission(src, Config.AdminPermission) then return end
    end

    DoorStates[doorIndex] = not DoorStates[doorIndex]
    PersistState(doorIndex)
    BroadcastState(doorIndex)
    ApplyLinkedDoors(doorIndex)

    print(('[^2door_lock_baashastudios^7] Door #%d toggled by player %d via %s. Locked: %s'):format(
        doorIndex, src, method, tostring(DoorStates[doorIndex])
    ))
end)

-- ── Manager: add custom door ───────────────────────────────────────────────
RegisterNetEvent('doorlock:manager:addDoor', function(data)
    local src = source
    if not IsPlayerAceAllowed(src, 'command') and not Bridge.HasPermission(src, Config.AdminPermission) then
        Bridge.Notify(src, 'No permission.', 'error', 3000)
        return
    end
    if type(data) ~= 'table' or type(data.name) ~= 'string' or #data.name < 1 then return end

    local codes          = (type(data.codes)          == 'table') and json.encode(data.codes)          or '[]'
    local authJobs       = (type(data.authorizedJobs)  == 'table' and #data.authorizedJobs  > 0) and json.encode(data.authorizedJobs)  or nil
    local authItems      = (type(data.authorizedItems) == 'table' and #data.authorizedItems > 0) and json.encode(data.authorizedItems) or nil

    -- Insert door A
    MySQL.insert(
        'INSERT INTO door_lock_custom (name,obj_hash,coords_x,coords_y,coords_z,heading,distance,lock_type,codes,authorized_jobs,authorized_items) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        { data.name, data.objHash or 0, data.x or 0, data.y or 0, data.z or 0,
          data.heading or 0, data.distance or 1.5, data.lockType or 'pin', codes, authJobs, authItems },
        function(idA)
            if not idA then return end
            if type(data.doorB) == 'table' then
                -- Double door: set group_id = idA on door A, then insert door B
                MySQL.update('UPDATE door_lock_custom SET group_id = ? WHERE id = ?', { idA, idA })
                local b = data.doorB
                MySQL.insert(
                    'INSERT INTO door_lock_custom (name,obj_hash,coords_x,coords_y,coords_z,heading,distance,lock_type,codes,authorized_jobs,authorized_items,group_id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
                    { data.name .. ' B', b.hash or 0, b.x or 0, b.y or 0, b.z or 0,
                      b.heading or 0, data.distance or 1.5, data.lockType or 'pin', codes, authJobs, authItems, idA },
                    function()
                        LoadAndBroadcastCustomDoors()
                        print(('[^2door_lock_baashastudios^7] Admin %d added double door: %s'):format(src, data.name))
                    end
                )
            else
                LoadAndBroadcastCustomDoors()
                print(('[^2door_lock_baashastudios^7] Admin %d added door: %s'):format(src, data.name))
            end
        end
    )
end)

-- ── Manager: edit custom door ──────────────────────────────────────────────
RegisterNetEvent('doorlock:manager:editDoor', function(data)
    local src = source
    if not IsPlayerAceAllowed(src, 'command') and not Bridge.HasPermission(src, Config.AdminPermission) then
        Bridge.Notify(src, 'No permission.', 'error', 3000)
        return
    end
    local customId = tonumber(data.customId)
    if not customId or type(data.name) ~= 'string' or #data.name < 1 then return end

    local codes     = (type(data.codes)          == 'table') and json.encode(data.codes)          or '[]'
    local authJobs  = (type(data.authorizedJobs)  == 'table' and #data.authorizedJobs  > 0) and json.encode(data.authorizedJobs)  or nil
    local authItems = (type(data.authorizedItems) == 'table' and #data.authorizedItems > 0) and json.encode(data.authorizedItems) or nil

    MySQL.update(
        'UPDATE door_lock_custom SET name=?, lock_type=?, codes=?, authorized_jobs=?, authorized_items=?, distance=? WHERE id=?',
        { data.name, data.lockType or 'pin', codes, authJobs, authItems, data.distance or 1.5, customId },
        function()
            LoadAndBroadcastCustomDoors()
            print(('[^2door_lock_baashastudios^7] Admin %d edited door id: %d'):format(src, customId))
        end
    )
end)

-- ── Manager: delete custom door ────────────────────────────────────────────
RegisterNetEvent('doorlock:manager:deleteDoor', function(customId)
    local src = source
    if not IsPlayerAceAllowed(src, 'command') and not Bridge.HasPermission(src, Config.AdminPermission) then
        Bridge.Notify(src, 'No permission.', 'error', 3000)
        return
    end
    customId = tonumber(customId)
    if not customId then return end
    MySQL.query('DELETE FROM door_lock_custom WHERE id = ?', { customId }, function()
        LoadAndBroadcastCustomDoors()
        print(('[^2door_lock_baashastudios^7] Admin %d deleted custom door id: %d'):format(src, customId))
    end)
end)

-- ── Admin command ─────────────────────────────────────────────────────────
Bridge.RegisterAdminCommand('dooradmin', 'Force toggle nearest door (Admin only)', function(source)
    TriggerClientEvent('doorlock:adminToggle', source)
end)
