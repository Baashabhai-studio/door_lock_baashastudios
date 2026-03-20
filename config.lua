Config = {}

-- ── Framework ─────────────────────────────────────────────────────────────
-- 'qbcore'  →  requires qb-core
-- 'esx'     →  requires es_extended (ESX Legacy)
Config.Framework = 'qbcore'

-- ── General settings ──────────────────────────────────────────────────────
Config.InteractKey    = 38       -- GTA key: E
Config.DrawDistance   = 3.5      -- metres — show label when within this range
Config.MaxPinLength   = 6        -- max digits a PIN can be
Config.PinAttempts    = 3        -- wrong attempts before lockout
Config.LockoutTime    = 60       -- seconds the panel is blocked after too many failures
Config.UseDatabase    = true     -- persist door states through server restarts (requires oxmysql)
Config.AdminPermission = 'admin' -- permission level for /dooradmin (QBCore: 'admin' | ESX: ignored, uses group)

-- ── Notifications (uses ox_lib notify) ───────────────────────────────────
Config.Notify = {
    unlocked = { title = 'Access Granted',   description = 'Door has been unlocked.',          type = 'success', duration = 3000 },
    locked   = { title = 'Door Locked',      description = 'Door has been secured.',           type = 'primary', duration = 3000 },
    denied   = { title = 'Access Denied',    description = 'Invalid credentials.',             type = 'error',   duration = 3000 },
    lockout  = { title = 'System Lockout',   description = 'Too many failed attempts. Locked for %ds.', type = 'error', duration = 5000 },
    no_item  = { title = 'Access Denied',    description = 'You do not have the required access card.',  type = 'error', duration = 3000 },
    no_job   = { title = 'Unauthorized',     description = 'Personnel access not authorized.',           type = 'error', duration = 3000 },
    consumed = { title = 'Card Used',        description = 'Access card was consumed.',                  type = 'primary', duration = 3000 },
}

--[[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DOOR CONFIGURATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  lockType options:
    'pin'       — numpad PIN required
    'job'       — authorized job/grade auto-unlocks without PIN
    'item'      — player must have item in inventory
    'any'       — job/item unlocks directly; fallback to PIN for others
    'pin_or_job'— PIN OR authorized job (no items)

  Per-door fields:
    name            string    — display name shown on keypad and label
    objName         string    — prop model hash name
    objCoords       vec3      — world coords of the object
    heading         number    — heading to reset door to when locked
    distance        number    — max interaction distance (default 1.5)
    locked          bool      — default lock state on first run
    lockType        string    — see above
    codes           table     — list of valid PIN strings (PIN types only)
    authorizedJobs  table     — { name, grade } pairs
    authorizedItems table     — item name strings
    consumeItem     bool      — remove item from inventory on use
    autoLock        number    — seconds before auto-relocking after unlock (0 = never)
    color           string    — hex accent color for keypad UI (#F0B429 = gold)
    icon            string    — Font Awesome class shown in label

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
]]

Config.Doors = {

    -- Add your doors here, or use /doormanager in-game to add them without editing this file.

}
