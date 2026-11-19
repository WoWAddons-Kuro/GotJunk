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
| `FoodWaterMode` | `lowlevel` | `never` = food/drink (classID 0, subclass 5) is never junk; `lowlevel` = the rules below apply |
| `FoodWater_ExcessNonBuff` | false | level-appropriate **non-buff** food/water: per item keep the fullest `FoodWaterKeepStacks` slots, the rest are junk |
| `FoodWaterKeepStacks` | 3 | N for the excess rule |
| `FoodWater_LowLevelBuffEligible` | true | Well Fed food whose `minLevel + 10 <= playerLevel` is junk |
| `FoodWater_OffClassBuffEligible` | false | Well Fed food naming a stat and none of them useful to the class (stamina/health never count) is junk |

Buff detection: `GJ.FoodProfile(itemID)` scans a hidden `GameTooltip` once per item for a "well fed" line and records which stat words appear; cached. Non-buff food/water is junk when low-level (`minLevel + 10 <= playerLevel`) or an excess stack. The table continues:

| key | default | meaning |
|---|---|---|
| `KeepClearSlots` | 1 | auto-drop is considered only while `freeSlots < KeepClearSlots` |
| `AutoDrop_Below10c` | false | full-stack value must be `< 10` copper |
| `AutoDrop_Below2Pct` | false | full-stack value must be `< 0.02 * Junk_TotalValue` |

**Drop sizing.** `GJ.AutoDrop_Plan(includeLoot)` computes `deficit = (KeepClearSlots + LootSlotsNeeded) - FreeSlots` and takes the worst-first prefix of the junk list whose every slot passes the ticked thresholds (AND, Q4 answer B), stopping at the first keeper. `LootSlotsNeeded` walks the open loot window: coins cost 0; an item that fits into an existing partial stack (same itemID with room) costs 0; otherwise `ceil(quantity / maxStack)`. **Worth-guard** (loot path only): `IncomingLoot_FloorValue` = the lowest `price * maxStack` among loot entries that are junk-ish by our own rules (grey/white, sellable, not quest, not protected); non-junk loot counts as `math.huge` so it never blocks. A bag slot joins the plan only if its full-stack value is strictly below that floor; the first slot that fails stops the plan (`blockedBy`) and, if nothing was dropped, the pickup is left to fail with a chat line. Q1 answer A, Q2 answer A. The loot-click handler drops the whole plan (Era allows several deletes per click; Forever one, so it prints "still N short - click again"). The red "pending" colouring uses the plan with `includeLoot=false`.

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
- [ ] Show standalone panel   [ ] Hide minimap button
- Panel: ( ) account wide / ( ) per character   [ ] Lock panel position  (see "Panel scope")
- Protected items list with a `Clear` button (text)

## Slash `/gotjunk`
`(none)` toggle panel · `options` · `lock` · `reset` (position) · `drop` (destroy worst slot — only
works from a keybound macro/hardware event) · `protect [itemlink|itemID]` toggle · `protect list` · `status`.

## Saved variables (account-wide, Q5)
```lua
GotJunkDB = {
  Version = 1,
  KeepClearSlots = 1, AutoDrop_Below10c = false, AutoDrop_Below2Pct = false,
  ShowPanel = nil --[[decided on first login]],
  PanelScope = "account" --[["account" | "character"]], Locked = false, Position = { point, x, y },
  Minimap = { hide = false },
  Protect = { [itemID] = true },
}
GotJunkCharDB = { Protect = {}, Locked = false, Position = { point, x, y } }
```

### Panel scope (options "Panel" section)
Radio `Panel position and lock are account wide` (default) / `... per character`, saved as
`GotJunkDB.PanelScope`. `PanelStore()` returns `GotJunkDB` or `GotJunkCharDB` accordingly and is the
**only** path to `Locked` / `Position` (drag, `/gotjunk lock`, `/gotjunk reset`, tooltip hint, options
checkbox). Switching scope copies nothing: the panel re-anchors from the newly selected store (default
anchor if that store has no position yet), and each store keeps its own values for switching back.

## Files
```
GotJunk/
  GotJunk.toc  GotJunk.lua  Libs/{LibStub,CallbackHandler-1.0,LibDataBroker-1.1,LibDBIcon-1.0}
  README.md  CHANGELOG.md  LICENSE  .pkgmeta  .gitignore  SPEC.md
```

## Protected lists (v2) — three tiers, union semantics

Three lists; an item is protected if it is in **any** of them (union). No rules in v2 — the
user curates the built-in list by hand (owner supplies item IDs; the addon ships them).

| tier | storage | row actions |
|---|---|---|
| **Character** | `GotJunkCharDB.Protect[itemID] = true` (SavedVariablesPerCharacter). Hidden and unused unless `GotJunkDB.UsePerCharacter` is on. | Delete · **Promote** (→ account) |
| **Account** | `GotJunkDB.Protect[itemID] = true` (the existing table). Default destination for shift-right-click / `/gotjunk protect`. | Delete · **Demote** (→ character, only shown when per-char is enabled) |
| **Built-in** | `GJ.BuiltinProtect = { [itemID] = true }` in `BuiltinProtect.lua`; user removals in `GotJunkDB.BuiltinRemoved[itemID] = true` (account-wide, survive updates; new seeds still appear). | Remove / Restore |

`GJ.IsProtected(itemID)` = `CharProtect[id] or AccountProtect[id] or (Builtin[id] and not BuiltinRemoved[id])`.
Enabling per-character does **not** move or copy anything: account entries keep applying to
every character; the character list is simply an additional tier. Disabling it leaves
`GotJunkCharDB.Protect` intact but ignored.

Where new protections land: shift-right-click and `/gotjunk protect` add to the **account**
list by default; with per-character enabled they add to the **character** list (that is what
"per character" means to the user). `/gotjunk protect account <link>` forces account.

### UI — `Protected items` section on the options page
Three stacked list boxes (character box hidden unless per-char is enabled), each a `ScrollFrame`
with a pooled row list, ~6 rows visible, header with count:
```
[x] Use a per-character list on this character

Character (2)                                   [Copy list]
  [icon] [Shiny Bauble]              [Promote] [Delete]
Account (5)                                     [Copy list]
  [icon] [Bag of Marbles]            [Demote]  [Delete]
  [icon] [Skinning Knife]            [Demote]  [Delete]
Built-in (0)                                    [Copy list] [Restore all]
  [icon] [Flimsy Chain Vest]  (removed)         [Restore]

Add: [ editbox — shift-click an item link here ] [Add to account] [Add to character]
```
- Rows: icon, item link (tooltip on hover), action buttons. Uncached items show `item:ID`
  until `GET_ITEM_INFO_RECEIVED` re-renders.
- **Copy list**: opens a small frame with a read-only, pre-selected `EditBox` containing one
  line per item `itemID<TAB>Item Name` (name blank if uncached) so Ctrl-C grabs it. This is
  the hand-off format the owner pastes back to seed `BuiltinProtect.lua`.
- Removed built-ins are shown greyed in the built-in box with a Restore button.
- Promote: delete from character, add to account. Demote: delete from account, add to
  character. Both rescan.
- `Add to character` only visible when per-char is enabled. Add parses a link or a bare ID.

### Saved variables
```lua
-- TOC: ## SavedVariables: GotJunkDB   ## SavedVariablesPerCharacter: GotJunkCharDB
GotJunkDB.UsePerCharacter = false      -- account-wide switch (hidden tier until on)
GotJunkDB.Protect = { [itemID] = true }
GotJunkDB.BuiltinRemoved = { [itemID] = true }
GotJunkCharDB = { Protect = { [itemID] = true } }
```

### Files
- `BuiltinProtect.lua` — `GJ.BuiltinProtect = { --[[ [itemID] = true, -- Name ]] }` (empty
  seed; owner fills via the Copy-list hand-off).
- `ProtectUI.lua` — the three list boxes, copy frame, add row. Called from `CreateOptions`.

### Tooltip / status
`/gotjunk protect list` prints each with its tier. Tooltip unchanged.

## Plan
- [x] Spec
- [x] Scaffold repo, libs, TOC
- [x] `GotJunk.lua`: scan, ranking, delete, loot hook, LDB, panel, options, slash
- [x] README / CHANGELOG / PROJECT_STRUCTURE entry, initial commit
- [x] Full-stack-value ranking, ShowWhenFreeBelow gate, preview window, occupancy strip
- [x] In-game verification on Forever (1.60.1): display, tooltip rebuild, protect/drop all confirmed working
- [x] Protected lists v2: DB model (`GotJunkCharDB`, `UsePerCharacter`, `BuiltinRemoved`), `GJ.IsProtected`
- [x] `BuiltinProtect.lua` seed (5 items) + TOC entries
- [x] `ProtectUI.lua`: three list boxes, promote/demote/delete/un-protect/re-protect, Copy-list frame, add row
- [x] Food & water: never / low-level radio + excess / low-level-buff / off-class-buff checkboxes, tooltip-based buff detection
- [x] Auto-drop sized to incoming loot (`LootSlotsNeeded`, stack-merge aware) + worth-guard (`IncomingLoot_FloorValue`)
- [x] **Shippable** (owner sign-off, 2026-11-18). Release via `cmd\release.cmd`.

## After v1
- Owner supplies further built-in item IDs via Copy-list hand-off (ongoing).
- Trial `KeepClearSlots = 0`: if loot-sized dropping makes the reserve unnecessary, add a `Drop worst junk` keybinding for the auto-loot case.
- Lesson logged: two shipping bugs were Lua declaration-order errors (`local` used above its declaration binds a global). Keep every file's `local` state declarations at the top of the file, above all functions.

## Open questions / later
- Keybinding `GotJunk: Drop worst junk` (cheap to add if auto-loot users want it).
- Other flavours (Mists/Cata) — TOC lines only, untested.