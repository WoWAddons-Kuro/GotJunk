# GotJunk — spec

Ultra-simple addon: an ever-present line showing the **least valuable junk slot** in your bags,

```
[icon] x10 - 10c Worthless Sandals
```

Click it to destroy that slot. Optionally auto-destroys the worst slot when you loot and your
bags are (nearly) full. Classic Era + WoW Forever first (Interface 11509 / 16001).

## Hard constraint: `DeleteCursorItem()` needs a hardware event

Since 9.0.2 / Classic 1.14 `DeleteCursorItem()` is `#hwevent` (and `#noscript` on Mainline-coded
clients such as Forever; Forever also limits it to **one item per hardware event**).
See https://warcraft.wiki.gg/wiki/API:DeleteCursorItem.

Consequences (decisions):

- Every deletion happens **inside a click handler**: our panel/LDB `OnClick`, or a hooked
  **loot button** `OnMouseDown` (fires before the loot `OnClick`, so the slot is freed first).
- **At most one slot is destroyed per hardware event**, on all flavours (consistent behaviour).
- Auto-loot (`LOOT_OPENED` with no button click) cannot trigger a drop. When a drop is *pending*
  (thresholds met) the panel text and LDB text turn **red** so a click is one glance away.
- No timers, no `OnUpdate`; everything is event-driven (`BAG_UPDATE_DELAYED`, `GET_ITEM_INFO_RECEIVED`, `LOOT_OPENED`).

## Junk candidate (Q2 answer A)

A bag slot is a **JunkSlot** when all of:

| rule | source |
|---|---|
| quality is Poor (0) or Common (1) | `C_Item.GetItemInfo` / `GetItemInfo` quality (fallback: container info quality) |
| sell price > 0 and container `hasNoValue` is false | `GetItemInfo` 11th return |
| not a quest item (classID 12) and not in `db.Protect[itemID]` | `GetItemInfo` 12th return |
| not Hearthstone (6948) | hard-coded safety |
| not locked (`isLocked` false) | container info |

`JunkSlot_Value = sellPrice * stackCount` (current, shown). **Ranking and thresholds use `JunkSlot_MaxStackValue = sellPrice * maxStack`** (what the slot is worth when full � a slot holding 1x 5c pelt (max 1) is less worth keeping than 3x 1c water (max 20 = 20c)). Sorted ascending by MaxStackValue,
ties by itemID then bag/slot (deterministic). `Junk_TotalValue = Σ JunkSlot_Value`.
Items whose info is not cached yet are skipped and a rescan happens on `GET_ITEM_INFO_RECEIVED`.

Bags scanned: `0 .. (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS)`. Free slots counted only in
general-purpose bags (`GetContainerNumFreeSlots` bagFamily == 0).

## Auto-drop thresholds (settings)

| key | default | meaning |
|---|---|---|
| `AutoHide` | false | hide the panel when nothing is shown; off = panel always visible |
| `ShowWhenFreeBelow` | 3 | panel/LDB show the worst slot only while `freeSlots < ShowWhenFreeBelow` (0 = never); tooltip always lists everything |
| `FoodWaterMode` | `stacks` | `never` = food/drink (classID 0, subclass 5) is never junk; `stacks` = per item, keep the fullest `FoodWaterKeepStacks` slots, the rest are junk; `lowlevel` = junk only when `playerLevel >= minLevel + 10` (vendor tiers unlock at req. level 1/5/15/25/35/45/55, so 10 levels past the requirement a better tier exists — no mapping table needed) |
| `FoodWaterKeepStacks` | 3 | used by `stacks` mode |
| `KeepClearSlots` | 1 | auto-drop is considered only while `freeSlots < KeepClearSlots` |
| `AutoDrop_Below10c` | false | full-stack value must be `< 10` copper |
| `AutoDrop_Below2Pct` | false | full-stack value must be `< 0.02 * Junk_TotalValue` |

`AutoDrop_Pending(worstSlot)` = `freeSlots < KeepClearSlots` **and** at least one checkbox is on
**and** every ticked checkbox passes (AND, Q4 answer B). Only the single worst slot is considered.

Trigger: loot-button `OnMouseDown` (hooked). Era: `LootButton1..4`. Forever/Mainline: frames of
`LootFrame.ScrollBox` are hooked on each `LOOT_OPENED` (once per frame, flagged).

## Display

### LibDataBroker (`type = "data source"`, name `GotJunk`)
- `icon` = item icon of worst slot (addon icon when none), `text` = `x10 10c Worthless Sandals`
  (red when pending; `no junk` when empty).
- Left-click: destroy worst slot. Right-click: options. Shift-right-click: protect worst item.
- Tooltip: top 5 junk slots with values, total junk value, free slots, threshold status.
- LibDBIcon minimap button (hideable).

### Standalone panel
- One row: icon + `x10 - 10c Worthless Sandals`, draggable (unless locked), same clicks as LDB.
- Hidden when there are no candidates or free slots >= ShowWhenFreeBelow, EXCEPT during a **preview**: 30s after login and 30s after each hover (so it can be found and moved), or when `AutoHide` is off (default).
- **Occupancy strip** above the row: one 4px dot per general-bag slot, bright grey = occupied, dim grey = free, up to 20 per row (rows balanced, centred). Icon+text row centred beneath; icon desaturated when nothing to drop.
- `db.ShowPanel` is decided once at first login: `false` if an LDB display host is detected
  (callback registrations on `LibDataBroker_AttributeChanged*` other than ours, or a known host
  addon loaded: ChocolateBar, Bazooka, TitanClassic/Titan, Fortress, StatBlockCore, ButtonBin,
  DockingStation, NinjaPanel, ElvUI), else `true`. User can override in options afterwards.

## Settings panel (`Settings.RegisterCanvasLayoutCategory`, fallback `InterfaceOptions_AddCategory`)
- Slots to keep clear: slider 0–10 (default 1)
- [ ] Auto-drop below 10c slot max
- [ ] Auto-drop below 2% of all bag junk value
- [ ] Show standalone panel   [ ] Lock panel   [ ] Hide minimap button
- Protected items list with a `Clear` button (text)

## Slash `/gotjunk`
`(none)` toggle panel · `options` · `lock` · `reset` (position) · `drop` (destroy worst slot — only
works from a keybound macro/hardware event) · `protect [itemlink|itemID]` toggle · `protect list` · `status`.

## Saved variables (account-wide, Q5)
```lua
GotJunkDB = {
  Version = 1,
  KeepClearSlots = 1, AutoDrop_Below10c = false, AutoDrop_Below2Pct = false,
  ShowPanel = nil --[[decided on first login]], Locked = false, Position = { point, x, y },
  Minimap = { hide = false },
  Protect = { [itemID] = true },
}
```

## Files
```
GotJunk/
  GotJunk.toc  GotJunk.lua  Libs/{LibStub,CallbackHandler-1.0,LibDataBroker-1.1,LibDBIcon-1.0}
  README.md  CHANGELOG.md  LICENSE  .pkgmeta  .gitignore  SPEC.md
```

## Protected lists (v2) — decisions from Q1 (all three), Q2 B, Q3 A

Three independent sources; an item is protected if **any** says so.

| source | storage | editable |
|---|---|---|
| **Built-in list** | `GJ.BuiltinProtect = { [itemID] = "reason" }` in `BuiltinProtect.lua`; user removals in `GotJunkDB.BuiltinRemoved[itemID] = true` (account-wide, survive updates; new seeds still appear) | remove / restore |
| **Custom list** | `GotJunkDB.Protect[itemID] = true` (account) **or** `GotJunkCharDB.Protect[itemID] = true` when `GotJunkCharDB.UsePerCharacter` is on. Enabling per-character **copies** the account list into the character list once. | add / remove |
| **Rules** | `GotJunkDB.Rules.ProtectEmptySlotGear` (default **on**), `GotJunkDB.Rules.ProtectUpgrades` (default **off**) | toggle |

### Built-in seed content
Grey/white gear a fresh character would actually wear: the level 1–10 vendor/drop shoulders,
cloaks, belts, bracers, off-hands and the starter-class items that have no quest equivalent.
Curated by itemID (Classic Era IDs; Forever shares them). Each entry carries a one-word reason
shown in the list (`"shoulders"`, `"cloak"`…). ~30 entries to start; grows by issue reports.

### Rule: ProtectEmptySlotGear (default on)
Item is Armor/Weapon (classID 2/4), `GetItemInfo` equipLoc maps to an inventory slot via
`C_Item.GetItemInventorySlotInfo` / `GetInventorySlotInfo`, **and** `GetInventoryItemID("player", slot)`
is nil for that slot (either slot for rings/trinkets/weapons where two are possible). Then it is
*not* junk. Rescan on `PLAYER_EQUIPMENT_CHANGED`. This is what covers "first shoulderpads" without
hand-listing every one.

### Rule: ProtectUpgrades (default off, opt-in)
Same mapping; protected when the candidate's item level **>** the equipped item's level in that
slot. Kept off by default: grey/white ilvl differences are noise and this would hoard.

### UI — `Protected items` section on the options page
One scrollable list widget (`ScrollFrame` + row pool, 8 rows visible):
```
[icon] [Worn Shortsword]           built-in: weapon     [Remove]
[icon] [Ruined Pelt]               custom               [Remove]
[icon] [Flimsy Chain Vest]         built-in (removed)   [Restore]
       rule: gear for an empty equipment slot   [x]
       rule: gear that is an upgrade             [ ]
```
- Filter dropdown: All · Built-in · Custom. Removed built-ins are shown greyed with Restore.
- Add box: an EditBox you shift-click an item link into (+ `Add` button), same as `/gotjunk protect`.
- Checkbox `Custom list is per character` (`GotJunkCharDB.UsePerCharacter`).
- Buttons: `Clear custom list`, `Restore all built-ins`.
- Rows show item links (tooltip on hover). Uncached items show the ID until
  `GET_ITEM_INFO_RECEIVED`.

### Saved variables
```lua
-- TOC: ## SavedVariables: GotJunkDB   ## SavedVariablesPerCharacter: GotJunkCharDB
GotJunkDB.BuiltinRemoved = { [itemID] = true }
GotJunkDB.Rules = { ProtectEmptySlotGear = true, ProtectUpgrades = false }
GotJunkCharDB = { UsePerCharacter = false, Protect = {} }
```

### Tooltip / status
Tooltip footer gains `N protected (built-in B, custom C, rule R)`; `/gotjunk protect list`
prints each with its source.

## Plan
- [x] Spec
- [x] Scaffold repo, libs, TOC
- [x] `GotJunk.lua`: scan, ranking, delete, loot hook, LDB, panel, options, slash
- [x] README / CHANGELOG / PROJECT_STRUCTURE entry, initial commit
- [x] Full-stack-value ranking, ShowWhenFreeBelow gate, preview window, occupancy strip
- [ ] In-game verification of the Forever loot-button hook (`LootFrame.ScrollBox` item frames)
- [ ] Protected lists v2: DB model + `GotJunkCharDB` + per-char copy-on-enable
- [ ] `BuiltinProtect.lua` seed (research Classic itemIDs for level 1–10 grey/white shoulders etc.)
- [ ] Rules: ProtectEmptySlotGear (on), ProtectUpgrades (off) + `PLAYER_EQUIPMENT_CHANGED` rescan
- [ ] Options: scrollable protected-list widget, filter, add box, per-char checkbox

## Open questions / later
- Keybinding `GotJunk: Drop worst junk` (cheap to add if auto-loot users want it).
- Other flavours (Mists/Cata) — TOC lines only, untested.