-- ── BaashaBhai Door Lock — Client Bridge ──────────────────────────────────
-- Provides a unified Bridge table regardless of which framework is installed.
-- Set Config.Framework in config.lua to switch between 'qbcore' and 'esx'.

Bridge = {}

-- ── QBCore ─────────────────────────────────────────────────────────────────
if Config.Framework == 'qbcore' then
    local QBCore = exports['qb-core']:GetCoreObject()

    --- Returns { name: string, grade: number } or nil
    function Bridge.GetPlayerJob()
        local pdata = QBCore.Functions.GetPlayerData()
        if not pdata or not pdata.job then return nil end
        return {
            name  = pdata.job.name,
            grade = pdata.job.grade and pdata.job.grade.level or 0,
        }
    end

    --- Returns true if the player has at least 1 of the given item
    function Bridge.HasItem(item)
        return QBCore.Functions.HasItem(item)
    end

    --- Show a notification to the local player
    --- @param msg      string
    --- @param type     string  'success' | 'error' | 'primary' | 'warning'
    --- @param duration number  milliseconds
    function Bridge.Notify(msg, type, duration)
        QBCore.Functions.Notify(msg, type, duration)
    end

-- ── ESX Legacy ─────────────────────────────────────────────────────────────
elseif Config.Framework == 'esx' then
    local ESX = exports['es_extended']:getSharedObject()

    function Bridge.GetPlayerJob()
        local pdata = ESX.GetPlayerData()
        if not pdata or not pdata.job then return nil end
        return {
            name  = pdata.job.name,
            grade = pdata.job.grade or 0,
        }
    end

    function Bridge.HasItem(item)
        local pdata = ESX.GetPlayerData()
        if pdata and pdata.inventory then
            for _, slot in ipairs(pdata.inventory) do
                if slot.name == item and slot.count > 0 then
                    return true
                end
            end
        end
        return false
    end

    -- Map QBCore notify types to ESX types
    local typeMap = { success = 'success', error = 'error', primary = 'info', warning = 'info' }

    function Bridge.Notify(msg, type, duration)
        local esxType = typeMap[type] or 'info'
        -- ESX Legacy 1.9+ supports type + duration; older builds only take msg
        local ok, err = pcall(function()
            ESX.ShowNotification(msg, esxType, duration)
        end)
        if not ok then
            ESX.ShowNotification(msg)
        end
    end

-- ── Unknown framework ──────────────────────────────────────────────────────
else
    print('^1[door_lock_baashastudios] Unknown Config.Framework: "' .. tostring(Config.Framework) .. '" — set it to "qbcore" or "esx" in config.lua^7')

    function Bridge.GetPlayerJob() return nil end
    function Bridge.HasItem()      return false end
    function Bridge.Notify(msg)    print('[DoorLock] ' .. tostring(msg)) end
end
