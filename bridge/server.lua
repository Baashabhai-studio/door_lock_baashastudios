-- ── BaashaBhai Door Lock — Server Bridge ──────────────────────────────────
-- Provides a unified Bridge table regardless of which framework is installed.
-- Set Config.Framework in config.lua to switch between 'qbcore' and 'esx'.

Bridge = {}

-- ── QBCore ─────────────────────────────────────────────────────────────────
if Config.Framework == 'qbcore' then
    -- Lazy init: avoids timing issues during resource restarts
    local _QBCore = nil
    local function GetQB()
        if not _QBCore then _QBCore = exports['qb-core']:GetCoreObject() end
        return _QBCore
    end

    --- Returns true if the player exists server-side
    function Bridge.PlayerExists(src)
        return GetQB().Functions.GetPlayer(src) ~= nil
    end

    --- Returns { name: string, grade: number } or nil
    function Bridge.GetPlayerJob(src)
        local player = GetQB().Functions.GetPlayer(src)
        if not player then return nil end
        local job = player.PlayerData.job
        return {
            name  = job.name,
            grade = job.grade and job.grade.level or 0,
        }
    end

    --- Remove an item from the player's inventory
    function Bridge.RemoveItem(src, item, count)
        local player = GetQB().Functions.GetPlayer(src)
        if player then
            player.Functions.RemoveItem(item, count)
        end
    end

    --- Returns true if the player has the given permission level
    function Bridge.HasPermission(src, permission)
        return GetQB().Functions.HasPermission(src, permission)
    end

    --- Send a notification to a specific player
    function Bridge.Notify(src, msg, type, duration)
        TriggerClientEvent('QBCore:Notify', src, msg, type or 'primary', duration or 3000)
    end

    --- Register an admin-only command
    function Bridge.RegisterAdminCommand(name, help, cb)
        GetQB().Commands.Add(name, help, {}, false, function(source)
            cb(source)
        end, Config.AdminPermission)
    end

-- ── ESX Legacy ─────────────────────────────────────────────────────────────
elseif Config.Framework == 'esx' then
    -- Lazy init: avoids timing issues during resource restarts
    local _ESX = nil
    local function GetESX()
        if not _ESX then _ESX = exports['es_extended']:getSharedObject() end
        return _ESX
    end

    function Bridge.PlayerExists(src)
        return GetESX().GetPlayerFromId(src) ~= nil
    end

    function Bridge.GetPlayerJob(src)
        local xPlayer = GetESX().GetPlayerFromId(src)
        if not xPlayer then return nil end
        local job = xPlayer.getJob()
        return {
            name  = job.name,
            grade = job.grade or 0,
        }
    end

    function Bridge.RemoveItem(src, item, count)
        local xPlayer = GetESX().GetPlayerFromId(src)
        if xPlayer then
            xPlayer.removeInventoryItem(item, count)
        end
    end

    function Bridge.HasPermission(src, permission)
        local xPlayer = GetESX().GetPlayerFromId(src)
        if not xPlayer then return false end
        local group = xPlayer.getGroup()
        return group == 'admin' or group == 'superadmin'
    end

    function Bridge.Notify(src, msg, type, duration)
        TriggerClientEvent('esx:showNotification', src, msg)
    end

    function Bridge.RegisterAdminCommand(name, help, cb)
        GetESX().RegisterCommand(name, 'admin', function(source, args, user)
            cb(source)
        end, false, { help = help })
    end

-- ── Unknown framework ──────────────────────────────────────────────────────
else
    print('^1[door_lock_baashastudios] Unknown Config.Framework: "' .. tostring(Config.Framework) .. '" — set it to "qbcore" or "esx" in config.lua^7')

    function Bridge.PlayerExists()        return true end
    function Bridge.GetPlayerJob()        return nil  end
    function Bridge.RemoveItem()                    end
    function Bridge.HasPermission()       return false end
    function Bridge.Notify(src, msg)      print('[DoorLock] ' .. tostring(msg)) end
    function Bridge.RegisterAdminCommand(name, help, cb)
        RegisterCommand(name, function(source) cb(source) end, true)
    end
end
