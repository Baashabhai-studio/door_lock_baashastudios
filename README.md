# BaashaBhai Door Lock

A luxury security door lock system for FiveM. Supports **QBCore** and **ESX Legacy** via a clean bridge architecture — one script, any framework.

**Free to use. Made by BaashaBhai.**

---

## Features

- Multi-framework: QBCore and ESX Legacy (bridge system — easy to extend)
- 5 lock types: PIN, Job, Item/Keycard, PIN-or-Job, Any (job → item → PIN fallback)
- Double door support with live in-game prop pointing
- In-game Door Manager UI — add, edit, delete doors without editing config files
- Persistent door states across server restarts (oxmysql)
- Auto-lock timer per door
- Linked/grouped double doors sync together
- PIN lockout after too many wrong attempts
- Server-side PIN validation (codes never sent to client)
- Admin force-toggle command
- Custom hex accent color and icon per door

---

## Dependencies

### Required for all setups

| Resource | Link | Notes |
|---|---|---|
| `oxmysql` | https://github.com/overextended/oxmysql | Door state persistence |

> Set `Config.UseDatabase = false` in `config.lua` to skip oxmysql (states won't persist through restarts).

---

### If using QBCore

| Resource | Link | Notes |
|---|---|---|
| `qb-core` | https://github.com/qbcore-framework/qb-core | Core framework |

Set in `config.lua`:
```lua
Config.Framework = 'qbcore'
```

**`server.cfg` load order:**
```
ensure oxmysql
ensure qb-core
ensure door_lock_baashastudios
```

---

### If using ESX Legacy

| Resource | Link | Notes |
|---|---|---|
| `es_extended` | https://github.com/esx-framework/esx_core | ESX Legacy (1.9+) |

Set in `config.lua`:
```lua
Config.Framework = 'esx'
```

**`server.cfg` load order:**
```
ensure oxmysql
ensure es_extended
ensure door_lock_baashastudios
```

---

## Installation

1. Drop the `door_lock_baashastudios` folder into your server's `resources` directory.
2. Add `ensure door_lock_baashastudios` to `server.cfg` **after** your framework.
3. Open `config.lua` and set `Config.Framework` to `'qbcore'` or `'esx'`.
4. Start your server. The SQL tables are created automatically on first launch — no manual SQL needed.

---

## Config (`config.lua`)

### Framework & General

```lua
Config.Framework = 'qbcore'  -- 'qbcore' or 'esx'

Config.InteractKey     = 38    -- GTA V key code (38 = E)
Config.DrawDistance    = 3.5   -- metres — door label appears within this range
Config.MaxPinLength    = 6     -- max digits in a PIN
Config.PinAttempts     = 3     -- wrong attempts before lockout
Config.LockoutTime     = 60    -- lockout duration in seconds
Config.UseDatabase     = true  -- false = states reset on restart (no oxmysql needed)
Config.AdminPermission = 'admin'
```

---

## Lock Types

| Type | Behaviour |
|---|---|
| `pin` | Opens a numpad — correct PIN required |
| `job` | Authorized job + grade unlocks instantly (no UI) |
| `item` | Player must have a required item in inventory |
| `pin_or_job` | Authorized job = instant unlock; everyone else gets the numpad |
| `any` | Tries in order: job → item → PIN |

---

## Door Configuration Fields

| Field | Type | Notes |
|---|---|---|
| `name` | string | Display name on label and keypad |
| `objName` | string | Prop model hash name (e.g. `'prop_gate_prison_01'`) |
| `objCoords` | vec3 | World position of the door prop |
| `heading` | number | Heading the door resets to when locked |
| `locked` | bool | Default lock state on first run |
| `lockType` | string | See Lock Types table above |
| `distance` | number | Interaction distance in metres (default `1.5`) |
| `codes` | table | Valid PIN strings: `{ '1234', '5678' }` |
| `authorizedJobs` | table | `{ { name='police', grade=2 }, ... }` |
| `authorizedItems` | table | Item names: `{ 'keycard_police', 'master_key' }` |
| `consumeItem` | bool | Remove item on use (default `false`) |
| `autoLock` | number | Seconds before auto-relock after unlock (`0` = never) |
| `color` | string | Hex accent color for keypad (e.g. `'#F0B429'`) |
| `icon` | string | Font Awesome class for world label |

---

## Example Doors

### PIN only
```lua
{
    name      = 'Garage Side Door',
    objName   = 'prop_gate_prison_01',
    objCoords = vec3(100.0, 200.0, 30.0),
    heading   = 0.0,
    locked    = true,
    lockType  = 'pin',
    codes     = { '1234', '9999' },
    autoLock  = 0,
    color     = '#3B82F6',
    icon      = 'fa-solid fa-lock',
},
```

### Job access
```lua
{
    name      = 'Police Armory',
    objName   = 'prop_gate_prison_01',
    objCoords = vec3(456.0, -982.0, 30.7),
    heading   = 90.0,
    locked    = true,
    lockType  = 'job',
    authorizedJobs = {
        { name = 'police',  grade = 2 },
        { name = 'sheriff', grade = 2 },
    },
    autoLock  = 30,
    color     = '#3B82F6',
    icon      = 'fa-solid fa-gun',
},
```

### Item / keycard
```lua
{
    name            = 'VIP Lounge',
    objName         = 'prop_gate_prison_01',
    objCoords       = vec3(0.0, 0.0, 0.0),
    heading         = 0.0,
    locked          = true,
    lockType        = 'item',
    authorizedItems = { 'vip_card', 'gold_keycard' },
    consumeItem     = false,
    autoLock        = 60,
    color           = '#F0B429',
    icon            = 'fa-solid fa-star',
},
```

### Any (job → item → PIN fallback)
```lua
{
    name            = 'Manager Office',
    objName         = 'prop_gate_prison_01',
    objCoords       = vec3(0.0, 0.0, 0.0),
    heading         = 0.0,
    locked          = true,
    lockType        = 'any',
    codes           = { '9999' },
    authorizedJobs  = { { name = 'realestate', grade = 3 } },
    authorizedItems = { 'manager_keycard' },
    consumeItem     = false,
    autoLock        = 0,
    color           = '#A78BFA',
    icon            = 'fa-solid fa-briefcase',
},
```

---

## Commands

| Command | Who can use | Description |
|---|---|---|
| `/doormanager` | All players | Opens the in-game Door Manager panel |
| `/dooradmin` | Admin only | Force-toggles the nearest door regardless of lock type |

---

## Door Manager UI

The in-game manager (`/doormanager`) lets admins add, edit, and delete doors without touching config files. Changes save to the database and sync to all players instantly.

### Adding a single door
1. Stand near the door prop and run `/doormanager`
2. Click **+ ADD DOOR AT MY POSITION**
3. The script auto-scans for the nearest prop — green dot = detected
4. Fill in Door Name, Lock Type, credentials, and distance
5. Click **SAVE DOOR**

### Adding a double door (two linked props)
1. Run `/doormanager` → **+ ADD DOOR AT MY POSITION**
2. Check the **DOUBLE DOOR** checkbox
3. Click **⊕ POINT & SELECT BOTH DOORS**
4. The panel moves to the right — aim at **Door 1** and press **[E]**
5. Aim at **Door 2** and press **[E]**
6. Both props are captured — fill in the rest and click **SAVE DOOR**
7. Both doors will lock/unlock together automatically

### Editing a custom door
Click **EDIT** on any custom door row to update its settings.
> Doors from `config.lua` show **CONFIG** — edit them directly in the file.

### Deleting a custom door
Click **DEL** once to arm, click again (**CONFIRM?**) to delete.

---

## File Structure

```
door_lock_baashastudios/
├── bridge/
│   ├── client.lua     ← Framework calls (client-side): job check, item check, notify
│   └── server.lua     ← Framework calls (server-side): player check, remove item, permissions
├── client/
│   └── main.lua       ← Door proximity loop, UI handling, NUI callbacks
├── server/
│   └── main.lua       ← Door state, PIN validation, DB persistence, manager CRUD
├── html/
│   ├── index.html     ← Keypad UI + Door Manager overlay
│   ├── style.css      ← All styles
│   └── main.js        ← UI logic
├── config.lua         ← All settings and door definitions
├── fxmanifest.lua     ← Resource manifest
└── README.md          ← This file
```

**To add a new framework**, create `bridge/client.lua` and `bridge/server.lua` implementations and set the matching `Config.Framework` value.

---

## Notification Types

Valid `type` values for `Config.Notify` entries:

| Framework | Valid types |
|---|---|
| QBCore | `success`, `error`, `primary`, `warning` |
| ESX | `success`, `error`, `info` (mapped automatically) |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Script doesn't start | Check `Config.Framework` matches what's installed (`'qbcore'` or `'esx'`) |
| F8 error: `Style of type: inform` | Old config — change `type = 'inform'` to `type = 'primary'` in `Config.Notify` |
| Doors not locking visually | Check `objName` is the exact model hash name of the prop |
| Database tables not created | Ensure `oxmysql` starts **before** this resource in `server.cfg` |
| Double door scan detects same prop | Use **POINT & SELECT BOTH DOORS** — physically aim at each door separately |
| ESX: `/dooradmin` not working | Make sure the player's group is `'admin'` or `'superadmin'` in ESX |

---

## License

This project is licensed under the **GNU General Public License v3.0**.

- Free to use, modify, and redistribute
- Modified versions must also be released as open-source under GPL v3
- Cannot be relicensed as proprietary or sold as a closed-source product

See the [LICENSE](LICENSE) file for full terms, or visit https://www.gnu.org/licenses/gpl-3.0.txt

---

## Credits

**Made by BaashaBhai**
