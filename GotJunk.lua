-- GotJunk: always shows the least valuable grey/white bag slot; click to destroy it.
-- Optionally destroys it for you on a loot click when bags are (nearly) full.
-- See SPEC.md. Hard constraint: DeleteCursorItem() needs a hardware event, so every
-- deletion happens inside a click handler (ours, or a hooked loot button).
local ADDON_NAME, GJ = ...
_G.GotJunk = GJ

local DB_VERSION = 1
local ADDON_ICON = "Interface\\Icons\\INV_Misc_Bag_10_Green"
local HEARTHSTONE_ID = 6948
local QUEST_CLASS_ID = 12
local CONSUMABLE_CLASS_ID = 0
local FOOD_DRINK_SUBCLASS_ID = 5
-- Vendor food/water tiers in Classic unlock at required level 1, 5, 15, 25, 35, 45, 55: once the
-- player is this many levels past an item's required level, a better tier has been available.
local FOOD_TIER_SPAN = 10
local COLOR = "|cff9d9d9d"   -- poor-quality grey for the prefix

local DEFAULTS = {
  KeepClearSlots = 1,
  ShowWhenFreeBelow = 3,  -- display shows the worst slot only while free slots < this (0 = never)
  FoodWaterMode = "lowlevel",            -- "never" | "lowlevel" (junk when required level is 10+ below yours)
  FoodWater_ExcessNonBuff = false,       -- level-appropriate non-buff food/water beyond N stacks is junk
  FoodWaterKeepStacks = 3,               -- N for the excess rule
  FoodWater_LowLevelBuffEligible = true, -- Well Fed food that is low-level is junk
  FoodWater_OffClassBuffEligible = false,-- Well Fed food whose stats do nothing for this class is junk
  AutoHide = false,         -- hide the panel when nothing is eligible/shown (default off: always visible)
  Style = "classic",        -- "classic" rounded tooltip border | "flat" modern
  AutoDrop_Below10c = false,
  AutoDrop_Below2Pct = false,
  ShowPanel = nil,      -- decided on first login: false if an LDB display host is present
  Locked = false,
  Position = nil,       -- { point, x, y }
  Minimap = { hide = false },
  Protect = {},         -- account-wide protected list: [itemID] = true
  BuiltinRemoved = {},  -- built-in entries the user removed: [itemID] = true (persists across updates)
  UsePerCharacter = false, -- show/use the per-character tier (GotJunkCharDB.Protect)
}

local db

-- ---------------------------------------------------------------------------
-- utils / API shims (Era 1.15 and Forever 16001 both expose C_Container; keep fallbacks)
-- ---------------------------------------------------------------------------
local function Print(fmt, ...) print("|cffb0b0b0GotJunk|r: " .. string.format(fmt, ...)) end
GJ.Print = Print

local GetContainerNumSlots     = C_Container and C_Container.GetContainerNumSlots     or GetContainerNumSlots
local GetContainerNumFreeSlots = C_Container and C_Container.GetContainerNumFreeSlots or GetContainerNumFreeSlots
local PickupContainerItem      = C_Container and C_Container.PickupContainerItem      or PickupContainerItem
local GetItemInfo              = C_Item and C_Item.GetItemInfo or GetItemInfo

local function GetSlotInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then return nil end
    return info.itemID, info.stackCount, info.isLocked, info.hasNoValue, info.quality, info.iconFileID, info.hyperlink
  end
  local texture, count, locked, quality, _, _, link, _, noValue, itemID = GetContainerItemInfo(bag, slot)
  return itemID, count, locked, noValue, quality, texture, link
end

local NUM_BAGS = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

local function FormatMoney(copper)
  copper = math.floor(copper or 0)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  -- coin colours: gold yellow, silver white, copper grey (Blizzard's money frame palette)
  local G, S, C = "|cffffd700%dg|r", "|cffe6e6e6%ds|r", "|cff9d9d9d%dc|r"
  if g > 0 then return string.format(G .. " " .. S .. " " .. C, g, s, c) end
  if s > 0 then return string.format(S .. " " .. C, s, c) end
  return string.format(C, c)
end

-- ---------------------------------------------------------------------------
-- scan: build the ranked junk list
-- ---------------------------------------------------------------------------
GJ.JunkSlots = {}        -- ascending by maxStackValue (price * maxStack):
                         -- { bag, slot, itemID, name, link, icon, count, price, value, quality, maxStack, maxStackValue }
GJ.Junk_TotalValue = 0
GJ.FreeSlots = 0
GJ.Occupancy = {}         -- array over general-bag slots: true occupied / false free (drives the dot strip)
GJ.Scan_Incomplete = false  -- some item info was not cached; rescan on GET_ITEM_INFO_RECEIVED

-- Buff-food detection. GetItemInfo cannot tell food that grants Well Fed from plain food, so
-- scan the item's tooltip once for a "well fed" line and remember the stats it names. The
-- profile also decides "off-class": the buff names at least one stat and none suit this class.
local scanTip
local foodProfileCache = {}
local FOOD_STAT_WORDS = { "strength", "agility", "stamina", "intellect", "spirit", "mana", "health" }
-- Stats a class gets real use from. Stamina / health are universal and never count as off-class.
local CLASS_USEFUL_STATS = {
  WARRIOR = { strength = true, agility = true },
  PALADIN = { strength = true, intellect = true, spirit = true, mana = true },
  HUNTER  = { agility = true, intellect = true, mana = true },
  ROGUE   = { agility = true, strength = true },
  PRIEST  = { intellect = true, spirit = true, mana = true },
  SHAMAN  = { intellect = true, strength = true, agility = true, spirit = true, mana = true },
  MAGE    = { intellect = true, spirit = true, mana = true },
  WARLOCK = { intellect = true, spirit = true, mana = true },
  DRUID   = { intellect = true, spirit = true, agility = true, strength = true, mana = true },
}

-- Returns { buff = bool, stats = {name=true}, offClass = bool }, or nil if the tooltip had no
-- data yet (caller treats as "not cached" and rescans on GET_ITEM_INFO_RECEIVED).
function GJ.FoodProfile(itemID)
  local p = foodProfileCache[itemID]
  if p then return p end
  if not scanTip then
    scanTip = CreateFrame("GameTooltip", "GotJunkScanTip", nil, "GameTooltipTemplate")
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
  end
  scanTip:ClearLines()
  if scanTip.SetItemByID then scanTip:SetItemByID(itemID) else scanTip:SetHyperlink("item:" .. itemID) end
  if scanTip:NumLines() == 0 then return nil end
  p = { buff = false, stats = {}, offClass = false }
  for i = 1, scanTip:NumLines() do
    local fs = _G["GotJunkScanTipTextLeft" .. i]
    local text = fs and fs:GetText()
    if text then
      local lower = text:lower()
      if lower:find("well fed", 1, true) then
        p.buff = true
        for _, s in ipairs(FOOD_STAT_WORDS) do if lower:find(s, 1, true) then p.stats[s] = true end end
      end
    end
  end
  if p.buff then
    local _, class = UnitClass("player")
    local useful = CLASS_USEFUL_STATS[class] or {}
    local anyNamed, anyUseful = false, false
    for s in pairs(p.stats) do
      if s ~= "stamina" and s ~= "health" then
        anyNamed = true
        if useful[s] then anyUseful = true end
      end
    end
    p.offClass = anyNamed and not anyUseful
  end
  foodProfileCache[itemID] = p
  return p
end

local function IsJunkCandidate(itemID, noValue, containerQuality)
  if not itemID or noValue or itemID == HEARTHSTONE_ID or GJ.IsProtected(itemID) then return false end
  local name, link, quality, _, minLevel, _, _, maxStack, _, icon, price, classID, subclassID = GetItemInfo(itemID)
  if not name then return nil end  -- not cached yet
  quality = quality or containerQuality
  if quality == nil or quality > 1 then return false end
  if not price or price <= 0 then return false end
  if classID == QUEST_CLASS_ID then return false end
  if not maxStack or maxStack < 1 then maxStack = 1 end
  local isFoodWater = classID == CONSUMABLE_CLASS_ID and subclassID == FOOD_DRINK_SUBCLASS_ID
  return true, name, link, quality, icon, price, maxStack, isFoodWater, minLevel or 1
end

function GJ.Scan()
  local list, total, free, incomplete = {}, 0, 0, false
  local occupancy = {}   -- ordered per bag slot: true = occupied, false = free (general bags only)
  local playerLevel = UnitLevel("player") or 1
  for bag = 0, NUM_BAGS do
    local n = GetContainerNumSlots(bag) or 0
    if n > 0 then
      local f, family = GetContainerNumFreeSlots(bag)
      local general = (family or 0) == 0
      if general then free = free + (f or 0) end
      for slot = 1, n do
        local itemID, count, locked, noValue, cq, tex = GetSlotInfo(bag, slot)
        if general then occupancy[#occupancy + 1] = itemID ~= nil end
        if itemID and not locked then
          local ok, name, link, quality, icon, price, maxStack, isFoodWater, minLevel = IsJunkCandidate(itemID, noValue, cq)
          if ok == nil then incomplete = true
          elseif ok then
            local value = price * (count or 1)
            local food = isFoodWater and GJ.FoodProfile(itemID) or nil
            if isFoodWater and not food then incomplete = true end   -- tooltip not ready; rescan later
            list[#list + 1] = { bag = bag, slot = slot, itemID = itemID, name = name, link = link,
              icon = icon or tex, count = count or 1, price = price, value = value, quality = quality,
              maxStack = maxStack, maxStackValue = price * maxStack,
              isFoodWater = isFoodWater, minLevel = minLevel, food = food,
              isLowLevel = playerLevel >= (minLevel or 1) + FOOD_TIER_SPAN }
          end
        end
      end
    end
  end
  -- Food & water policy (SPEC "Food and water"). Applied after the full pass because the
  -- excess rule needs every slot of an item.
  --   never    : no food/water is ever junk.
  --   lowlevel : non-buff -> junk when low-level, or when an excess stack (if enabled);
  --              buff     -> junk when low-level (if enabled) or off-class (if enabled).
  local mode = db.FoodWaterMode or "lowlevel"
  local kept = {}
  if mode == "never" then
    for _, j in ipairs(list) do if not j.isFoodWater then kept[#kept + 1] = j end end
  else
    -- Excess: per itemID, among level-appropriate NON-buff food/water, keep the fullest N stacks.
    local excess = {}
    if db.FoodWater_ExcessNonBuff then
      local keepN = db.FoodWaterKeepStacks or 3
      local byItem = {}
      for _, j in ipairs(list) do
        if j.isFoodWater and j.food and not j.food.buff and not j.isLowLevel then
          byItem[j.itemID] = byItem[j.itemID] or {}; table.insert(byItem[j.itemID], j)
        end
      end
      for _, slots in pairs(byItem) do
        table.sort(slots, function(a, b) return a.count > b.count end)
        for i = keepN + 1, #slots do excess[slots[i]] = true end
      end
    end
    for _, j in ipairs(list) do
      local junk
      if not j.isFoodWater then junk = true
      elseif not j.food then junk = false                        -- profile unknown yet: be safe
      elseif j.food.buff then
        junk = (j.isLowLevel and db.FoodWater_LowLevelBuffEligible)
            or (j.food.offClass and db.FoodWater_OffClassBuffEligible)
      else
        junk = j.isLowLevel or excess[j]
      end
      if junk then kept[#kept + 1] = j end
    end
  end
  list = kept
  for _, j in ipairs(list) do total = total + j.value end
  -- Rank by what the slot is worth when FULL: a slot of 1x 5c pelt (max 1) beats 3x 1c water (max 20 = 20c).
  -- Among equal full-stack value (e.g. several stacks of the same item), the slot holding the
  -- LEAST actual value goes first: a 2/20 stack is destroyed before a 20/20 stack of the same thing.
  table.sort(list, function(a, b)
    if a.maxStackValue ~= b.maxStackValue then return a.maxStackValue < b.maxStackValue end
    if a.value ~= b.value then return a.value < b.value end
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    if a.bag ~= b.bag then return a.bag < b.bag end
    return a.slot < b.slot
  end)
  GJ.JunkSlots, GJ.Junk_TotalValue, GJ.FreeSlots, GJ.Scan_Incomplete, GJ.Occupancy = list, total, free, incomplete, occupancy
  GJ.Refresh()
end

function GJ.Worst() return GJ.JunkSlots[1] end

-- Is the auto-drop condition met for the worst slot right now? (AND of ticked boxes)
-- Does one junk slot pass the ticked thresholds? (AND of ticked boxes; none ticked = never)
local function SlotPassesThresholds(j)
  if not (db.AutoDrop_Below10c or db.AutoDrop_Below2Pct) then return false end
  if db.AutoDrop_Below10c and not (j.maxStackValue < 10) then return false end
  if db.AutoDrop_Below2Pct and not (j.maxStackValue < 0.02 * GJ.Junk_TotalValue) then return false end
  return true
end

-- How many NEW bag slots the open loot window would need. Loot that merges into an existing
-- partial stack (same itemID, room left) costs 0 slots; coins cost 0; everything else 1.
-- Only called while the loot frame is open, so GetNumLootItems is meaningful.
local function LootSlotsNeeded()
  local need = 0
  if not GetNumLootItems then return 0 end
  local n = GetNumLootItems() or 0
  if n == 0 then return 0 end
  -- partial stacks in bags, by itemID: how many more units each can absorb
  local room = {}
  for bag = 0, NUM_BAGS do
    local slots = GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local itemID, count = GetSlotInfo(bag, slot)
      if itemID then
        local _, _, _, _, _, _, _, maxStack = GetItemInfo(itemID)
        if maxStack and maxStack > 1 and (count or 1) < maxStack then
          room[itemID] = (room[itemID] or 0) + (maxStack - (count or 1))
        end
      end
    end
  end
  for i = 1, n do
    local _, _, quantity, _, _, _, _, _, _, isCoin = GetLootSlotInfo(i)
    local slotType = GetLootSlotType and GetLootSlotType(i)
    local isItem = slotType == nil and not isCoin or (Enum and Enum.LootSlotType and slotType == Enum.LootSlotType.Item) or slotType == 1
    if isItem then
      local link = GetLootSlotLink(i)
      local itemID = link and tonumber(link:match("item:(%d+)"))
      quantity = quantity or 1
      if itemID and room[itemID] and room[itemID] > 0 then
        local absorbed = math.min(room[itemID], quantity)
        room[itemID] = room[itemID] - absorbed
        quantity = quantity - absorbed
      end
      if quantity > 0 then
        local _, _, _, _, _, _, _, maxStack = itemID and GetItemInfo(itemID)
        need = need + math.ceil(quantity / math.max(1, maxStack or 1))
      end
    end
  end
  return need
end
GJ.LootSlotsNeeded = LootSlotsNeeded

-- How many junk slots auto-drop wants to destroy right now, and the ordered list of them.
--   deficit = (KeepClearSlots + lootSlotsNeeded) - FreeSlots
-- Each candidate must pass the thresholds; we take the worst-first prefix of the junk list.
-- lootSlotsNeeded is only counted when the loot window is open (the loot-click path).
-- Value of the incoming loot entries that need NEW slots, so a drop never trades better junk
-- for worse. Returns the lowest full-stack value among those entries (nil if none / unknown).
-- An entry that is *not* junk by our own rules (green+, protected, kept food...) is treated as
-- worth keeping: it returns math.huge so nothing blocks freeing space for it.
local function IncomingLoot_FloorValue()
  if not GetNumLootItems then return nil end
  local n = GetNumLootItems() or 0
  local floor
  for i = 1, n do
    local _, _, quantity, _, _, _, _, _, _, isCoin = GetLootSlotInfo(i)
    if not isCoin then
      local link = GetLootSlotLink(i)
      local itemID = link and tonumber(link:match("item:(%d+)"))
      if itemID then
        local _, _, quality, _, _, _, _, maxStack, _, _, price, classID = GetItemInfo(itemID)
        local isJunkish = quality and quality <= 1 and (price or 0) > 0 and classID ~= QUEST_CLASS_ID and not GJ.IsProtected(itemID)
        local v = isJunkish and (price * math.max(1, maxStack or 1)) or math.huge
        if not floor or v < floor then floor = v end
      end
    end
  end
  return floor
end
GJ.IncomingLoot_FloorValue = IncomingLoot_FloorValue

-- How many junk slots auto-drop wants to destroy right now, and the ordered list of them.
--   deficit = (KeepClearSlots + lootSlotsNeeded) - FreeSlots
-- Each candidate must pass the thresholds; we take the worst-first prefix of the junk list.
-- lootSlotsNeeded is only counted when the loot window is open (the loot-click path).
-- Worth-guard (loot path only): a bag slot is only destroyed if its full-stack value is
-- strictly LESS than the cheapest junk-ish item in the loot. Otherwise the plan stops there
-- and the pickup is allowed to fail ("Inventory is full") rather than lose ground.
-- Returns: count, plan, deficit, blockedBy (the first slot refused by the worth-guard, or nil)
function GJ.AutoDrop_Plan(includeLoot)
  local wantFree = (db.KeepClearSlots or 0) + (includeLoot and LootSlotsNeeded() or 0)
  local deficit = wantFree - GJ.FreeSlots
  if deficit <= 0 then return 0, {}, 0 end
  local floorValue = includeLoot and IncomingLoot_FloorValue() or nil
  local plan = {}
  local blockedBy
  for _, j in ipairs(GJ.JunkSlots) do
    if #plan >= deficit then break end
    if not SlotPassesThresholds(j) then break end            -- worst-first list; first keeper ends it
    if floorValue and not (j.maxStackValue < floorValue) then blockedBy = j; break end
    plan[#plan + 1] = j
  end
  return #plan, plan, deficit, blockedBy
end

-- Is the auto-drop condition met right now? (used for the red "pending" colouring)
function GJ.AutoDrop_Pending()
  local n = GJ.AutoDrop_Plan(false)
  return n > 0
end

-- ---------------------------------------------------------------------------
-- destroy (must be called from a hardware event handler)
-- ---------------------------------------------------------------------------
-- Destroy one specific junk slot (from the current scan). Returns true on success.
function GJ.DropSlot(w, reason)
  if not w then return false end
  if CursorHasItem() then ClearCursor() end
  -- re-validate the slot: bags may have shifted since the last scan
  local itemID, count = GetSlotInfo(w.bag, w.slot)
  if itemID ~= w.itemID then GJ.Scan(); return false end
  PickupContainerItem(w.bag, w.slot)
  local kind, cursorID = GetCursorInfo()
  if kind ~= "item" or cursorID ~= w.itemID then ClearCursor(); return false end
  DeleteCursorItem()
  if CursorHasItem() then ClearCursor(); return false end
  Print("%sdestroyed|r %s x%d (%s)%s", "|cffff6060", w.link or w.name, count or w.count, FormatMoney(w.price * (count or w.count)),
    reason and ("  [" .. reason .. "]") or "")
  -- Rescan now rather than waiting for BAG_UPDATE_DELAYED so the panel/tooltip reflect the
  -- drop immediately (callers that loop over a plan rescan again at the end; cheap).
  GJ.Scan()
  return true
end

function GJ.DropWorst(reason)
  return GJ.DropSlot(GJ.Worst(), reason)
end

-- ---------------------------------------------------------------------------
-- protected lists: three tiers, union. See SPEC "Protected lists (v2)".
--   character : GotJunkCharDB.Protect   (only when db.UsePerCharacter)
--   account   : GotJunkDB.Protect
--   builtin   : GJ.BuiltinProtect minus GotJunkDB.BuiltinRemoved
-- ---------------------------------------------------------------------------
local function CharProtect() return GotJunkCharDB and GotJunkCharDB.Protect or {} end

function GJ.IsProtected(itemID)
  if not itemID then return false end
  if db.UsePerCharacter and CharProtect()[itemID] then return true end
  if db.Protect[itemID] then return true end
  if GJ.BuiltinProtect and GJ.BuiltinProtect[itemID] and not db.BuiltinRemoved[itemID] then return true end
  return false
end

-- Which tier(s) an item sits in, for display: returns "character", "account", "builtin", "builtin-removed" or nil.
function GJ.ProtectTier(itemID)
  if CharProtect()[itemID] then return "character" end
  if db.Protect[itemID] then return "account" end
  if GJ.BuiltinProtect and GJ.BuiltinProtect[itemID] then return db.BuiltinRemoved[itemID] and "builtin-removed" or "builtin" end
  return nil
end

local function LinkOrID(itemID) local _, link = GetItemInfo(itemID); return link or ("item:" .. itemID) end

-- tier: "account" | "character". Default tier is character when per-char is on, else account.
function GJ.ProtectAdd(itemID, tier)
  if not itemID then return end
  tier = tier or (db.UsePerCharacter and "character" or "account")
  local list = tier == "character" and CharProtect() or db.Protect
  if list[itemID] then Print("%s is already in the %s list", LinkOrID(itemID), tier); return end
  list[itemID] = true
  Print("protected %s (%s list)", LinkOrID(itemID), tier)
  GJ.Scan(); if GJ.ProtectUI_Refresh then GJ.ProtectUI_Refresh() end
end

function GJ.ProtectRemove(itemID, tier)
  if not itemID then return end
  if tier == "builtin" then db.BuiltinRemoved[itemID] = true
  elseif tier == "character" then CharProtect()[itemID] = nil
  else db.Protect[itemID] = nil end
  Print("unprotected %s (%s list)", LinkOrID(itemID), tier or "account")
  GJ.Scan(); if GJ.ProtectUI_Refresh then GJ.ProtectUI_Refresh() end
end

function GJ.ProtectRestoreBuiltin(itemID)
  if itemID then db.BuiltinRemoved[itemID] = nil else wipe(db.BuiltinRemoved) end
  GJ.Scan(); if GJ.ProtectUI_Refresh then GJ.ProtectUI_Refresh() end
end

-- Promote: character -> account. Demote: account -> character.
function GJ.ProtectPromote(itemID) CharProtect()[itemID] = nil; db.Protect[itemID] = true; GJ.Scan(); if GJ.ProtectUI_Refresh then GJ.ProtectUI_Refresh() end end
function GJ.ProtectDemote(itemID)  db.Protect[itemID] = nil; CharProtect()[itemID] = true; GJ.Scan(); if GJ.ProtectUI_Refresh then GJ.ProtectUI_Refresh() end end

-- Shift-right-click on the display: toggle. If protected anywhere, remove from the tier it is in
-- (built-in -> mark removed); otherwise add to the default tier.
function GJ.ToggleProtect(itemID)
  if not itemID then return end
  local tier = GJ.ProtectTier(itemID)
  if tier == "builtin-removed" then GJ.ProtectRestoreBuiltin(itemID)
  elseif tier then GJ.ProtectRemove(itemID, tier)
  else GJ.ProtectAdd(itemID) end
end

-- ---------------------------------------------------------------------------
-- loot hook: OnMouseDown on loot buttons runs before the loot OnClick and is a hardware event
-- ---------------------------------------------------------------------------
local function OnLootMouseDown()
  -- Size the drop to the loot: deficit = keep-clear + slots the loot window needs - free.
  -- Try to destroy that many; Forever allows one DeleteCursorItem per hardware event, Era
  -- allows several, so loop until the plan is done or a delete stops working.
  local n, plan, deficit, blockedBy = GJ.AutoDrop_Plan(true)
  if n == 0 and blockedBy then
    -- Worth-guard: the cheapest incoming item is worth no more than our cheapest junk.
    -- Don't lose ground; let the pickup fail and say why.
    Print("|cffffb000not freeing space|r - incoming loot is worth no more than %s (%s full-stack)", blockedBy.link or blockedBy.name, FormatMoney(blockedBy.maxStackValue))
    return
  end
  if n == 0 then return end
  local dropped = 0
  for _, j in ipairs(plan) do
    if not GJ.DropSlot(j, string.format("auto-drop on loot, %d/%d", dropped + 1, n)) then break end
    dropped = dropped + 1
  end
  if dropped > 0 then
    GJ.Scan()
    if blockedBy and deficit > dropped then
      Print("|cffffb000stopped at|r %s - the rest of the loot is not worth more than it", blockedBy.link or blockedBy.name)
    elseif deficit > dropped then
      Print("|cffffb000still %d slot(s) short|r - click the loot again to drop more", deficit - dropped)
    end
  end
end

local hookedLootButtons = {}
local function HookLootButton(btn)
  if not btn or hookedLootButtons[btn] then return end
  hookedLootButtons[btn] = true
  btn:HookScript("OnMouseDown", OnLootMouseDown)
end

local function HookLootButtons()
  -- Era / classic LootFrame: LootButton1..N
  local i = 1
  while _G["LootButton" .. i] do HookLootButton(_G["LootButton" .. i]); i = i + 1 end
  -- Mainline-style (Forever): scroll box element frames, created lazily
  if LootFrame and LootFrame.ScrollBox and LootFrame.ScrollBox.ForEachFrame then
    LootFrame.ScrollBox:ForEachFrame(function(frame) HookLootButton(frame.Item or frame) end)
  end
end

-- ---------------------------------------------------------------------------
-- LibDataBroker + minimap
-- ---------------------------------------------------------------------------
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
local ldbObject
-- The standalone panel frame. Declared HERE, above every function that references it
-- (OnClick, ShowPanelTooltip, HidePanelTooltip, RefreshTooltip, Refresh, CreatePanel), so
-- they all close over the same upvalue. A later `local panel` would leave these functions
-- bound to an always-nil global - exactly the "panel is nil" tipdebug symptom.
local panel

local function OnClick(_, button)
  if button == "RightButton" then
    if IsShiftKeyDown() then
      local w = GJ.Worst()
      if w then GJ.ToggleProtect(w.itemID) else Print("nothing to protect - no eligible junk") end
    else GJ.OpenOptions() end
  else
    GJ.DropWorst()
  end
  GJ.RefreshTooltip()
end

-- Re-render the panel tooltip in place (if it is up) so a protect/drop shows its effect without
-- the player having to move the mouse off and back on.
-- Deferred one frame: the click triggers Scan -> Refresh, which resizes/re-anchors the panel;
-- that geometry change can fire OnLeave (hiding the tooltip) AFTER a synchronous re-render,
-- and IsMouseOver() is unreliable mid-click. After layout settles we re-check and re-run OnEnter.
-- ---------------------------------------------------------------------------
-- Panel tooltip: the ONLY code that builds it. Always a full teardown + rebuild so the
-- tooltip can never show stale rows after a protect/drop. Nothing else appends to it.
-- ---------------------------------------------------------------------------
local OnTooltipShow   -- forward declaration; body is defined below (shared with the LDB object)
function GJ.ShowPanelTooltip()
  local dbg = GJ.TipDebug
  if not panel then if dbg then Print("tipdebug: panel is nil") end return end
  GJ.Refresh()                       -- data first (lifts the gate while hovering)
  if dbg then
    Print("tipdebug: panel visible=%s mouseOver=%s  junkSlots=%d  OnTooltipShow=%s",
      tostring(panel:IsVisible()), tostring(panel:IsMouseOver()), #GJ.JunkSlots, tostring(OnTooltipShow))
  end
  -- Build on a throwaway: if construction errors, pcall reports it instead of a silent no-tooltip.
  local ok, err = pcall(function()
    GameTooltip:Hide()
    GameTooltip:ClearLines()
    local _, cy = panel:GetCenter()
    local below = cy and cy > UIParent:GetHeight() / 2
    GameTooltip:SetOwner(panel, below and "ANCHOR_BOTTOM" or "ANCHOR_TOP")
    OnTooltipShow(GameTooltip)
    if not db.Locked then GameTooltip:AddLine("Drag to move  (/gotjunk lock)", 0.5, 0.5, 0.5) end
    GameTooltip:Show()
  end)
  if dbg or not ok then
    Print("tipdebug: build ok=%s err=%s  owner=%s shown=%s lines=%d",
      tostring(ok), tostring(err), tostring(GameTooltip:GetOwner() and GameTooltip:GetOwner():GetName() or GameTooltip:GetOwner()),
      tostring(GameTooltip:IsShown()), GameTooltip:NumLines())
  end
end

function GJ.HidePanelTooltip()
  if panel and GameTooltip:IsOwned(panel) then GameTooltip:Hide() end
end

-- After any action (protect, drop) while the cursor is on the panel: rebuild from scratch.
-- Deferred one frame because the action's Scan->Refresh resizes the panel under the cursor
-- and IsMouseOver() is not trustworthy inside the click handler itself.
function GJ.RefreshTooltip()
  if not panel then return end
  C_Timer.After(0, function()
    if panel:IsVisible() and panel:IsMouseOver() then GJ.ShowPanelTooltip() end
  end)
end

OnTooltipShow = function(tt)
  tt:AddLine("GotJunk")
  if #GJ.JunkSlots == 0 then
    tt:AddLine("No junk in bags", 0.7, 0.7, 0.7)
  else
    for i = 1, math.min(5, #GJ.JunkSlots) do
      local j = GJ.JunkSlots[i]
      tt:AddDoubleLine(string.format("|T%s:14|t %s x%d/%d", tostring(j.icon), j.link or j.name, j.count, j.maxStack), string.format("%s |cff808080(%s max)|r", FormatMoney(j.value), FormatMoney(j.maxStackValue)), 1, 1, 1, 1, 0.82, 0)
    end
    tt:AddDoubleLine(string.format("%d junk slots total (ranked by full-stack value)", #GJ.JunkSlots), FormatMoney(GJ.Junk_TotalValue), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
  end
  tt:AddDoubleLine("Free slots", tostring(GJ.FreeSlots) .. " (keep " .. tostring(db.KeepClearSlots) .. " clear)", 0.7, 0.7, 0.7, 1, 1, 1)
  if db.AutoDrop_Below10c or db.AutoDrop_Below2Pct then
    tt:AddLine((function() local n = GJ.AutoDrop_Plan(false); if n > 0 then return string.format("|cffff4040Auto-drop pending: next loot click destroys %d slot(s)|r", n) end return "|cff60ff60Auto-drop armed|r - sizes the drop to the loot it is picking up" end)())
  end
  tt:AddLine(" ")
  tt:AddLine("|cffffffffLeft-click|r destroy worst slot", 0.8, 0.8, 0.8)
  tt:AddLine("|cffffffffRight-click|r options", 0.8, 0.8, 0.8)
  tt:AddLine("|cffffffffShift-right-click|r protect worst item", 0.8, 0.8, 0.8)
end

local function SetupLDB()
  if not LDB then return end
  ldbObject = LDB:NewDataObject("GotJunk", {
    type = "data source", label = "GotJunk", icon = ADDON_ICON, text = "no junk",
    OnClick = OnClick, OnTooltipShow = OnTooltipShow,
  })
  if DBIcon then DBIcon:Register("GotJunk", ldbObject, db.Minimap) end
end

-- Is any LDB display (ChocolateBar, Bazooka, Titan...) present? Decides the panel default.
local HOST_ADDONS = { "ChocolateBar", "Bazooka", "TitanClassic", "Titan", "Fortress", "StatBlockCore", "ButtonBin", "DockingStation", "NinjaPanel", "ElvUI" }
local function HasLDBHost()
  local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
  for _, n in ipairs(HOST_ADDONS) do if isLoaded(n) then return true end end
  if LDB and LDB.callbacks and LDB.callbacks.events then
    for eventName, handlers in pairs(LDB.callbacks.events) do
      if type(eventName) == "string" and eventName:find("^LibDataBroker_AttributeChanged") then
        for owner in pairs(handlers) do if owner ~= DBIcon and owner ~= GJ then return true end end
      end
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- standalone panel
-- ---------------------------------------------------------------------------

local function SavePosition()
  local point, _, _, x, y = panel:GetPoint(1)
  db.Position = { point, x, y }
end

local function RestorePosition()
  panel:ClearAllPoints()
  if db.Position then panel:SetPoint(db.Position[1], UIParent, db.Position[1], db.Position[2], db.Position[3])
  else panel:SetPoint("TOP", UIParent, "TOP", 0, -120) end
end

-- Occupancy strip: one tiny dot per bag slot, bright = occupied, dim = free. Rows of up to
-- DOTS_PER_ROW so a 16-slot starter set is one row and 80+ slots still fit in a few rows.
local DOT_SIZE, DOT_GAP, DOTS_PER_ROW, DOTS_TOP_PAD = 4, 2, 20, 5
local PANEL_ROW_HEIGHT = 24
local dots = {}

local function UpdateDots()
  local occ = GJ.Occupancy
  local n = #occ
  if n == 0 then for _, d in ipairs(dots) do d:Hide() end return 0, 0 end
  local rows = math.ceil(n / DOTS_PER_ROW)
  local perRow = math.ceil(n / rows)   -- balance rows (e.g. 28 slots -> 14 + 14, not 20 + 8)
  local stripWidth = perRow * (DOT_SIZE + DOT_GAP) - DOT_GAP
  for i = 1, n do
    local d = dots[i]
    if not d then
      d = panel:CreateTexture(nil, "ARTWORK")
      d:SetSize(DOT_SIZE, DOT_SIZE)
      d:SetTexture("Interface\\Buttons\\WHITE8x8")
      dots[i] = d
    end
    local row, col = math.floor((i - 1) / perRow), (i - 1) % perRow
    -- last row may be shorter; centre each row on its own
    local rowCount = math.min(perRow, n - row * perRow)
    local rowWidth = rowCount * (DOT_SIZE + DOT_GAP) - DOT_GAP
    d:ClearAllPoints()
    d:SetPoint("TOP", panel, "TOP", -rowWidth / 2 + col * (DOT_SIZE + DOT_GAP) + DOT_SIZE / 2, -(DOTS_TOP_PAD + row * (DOT_SIZE + DOT_GAP)))
    if occ[i] then d:SetVertexColor(0.85, 0.85, 0.85, 0.95) else d:SetVertexColor(0.4, 0.4, 0.4, 0.55) end
    d:Show()
  end
  for i = n + 1, #dots do dots[i]:Hide() end
  local width = stripWidth + 10
  local height = DOTS_TOP_PAD + rows * (DOT_SIZE + DOT_GAP) - DOT_GAP
  return width, height
end

-- Preview: force the panel visible (ignoring the free-slot gate) until this GetTime().
GJ.PreviewUntil = 0
local PREVIEW_SECONDS = 30
local previewTimer
function GJ.StartPreview(seconds)
  seconds = seconds or PREVIEW_SECONDS
  GJ.PreviewUntil = GetTime() + seconds
  if previewTimer then previewTimer:Cancel() end
  previewTimer = C_Timer.NewTimer(seconds + 0.1, function() previewTimer = nil; GJ.Refresh() end)
  GJ.Refresh()
end

-- Two looks for the panel. "classic" = Blizzard tooltip border; "flat" = solid dark fill with
-- a crisp 1px edge, no tiling art.
local PANEL_STYLES = {
  classic = {
    backdrop = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } },
    bg = { 0, 0, 0, 0.6 }, border = { 0.5, 0.5, 0.5, 0.8 },
  },
  flat = {
    backdrop = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } },
    bg = { 0.06, 0.06, 0.06, 0.85 }, border = { 0.25, 0.25, 0.25, 1 },
  },
}

function GJ.ApplyPanelStyle()
  if not (panel and panel.SetBackdrop) then return end
  local st = PANEL_STYLES[db.Style or "classic"] or PANEL_STYLES.classic
  panel:SetBackdrop(st.backdrop)
  panel:SetBackdropColor(unpack(st.bg))
  panel:SetBackdropBorderColor(unpack(st.border))
end

local function CreatePanel()
  if panel then return panel end
  panel = CreateFrame("Button", "GotJunkPanel", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  panel:SetSize(220, PANEL_ROW_HEIGHT)
  panel:SetFrameStrata("MEDIUM")
  panel:SetClampedToScreen(true)
  panel:SetMovable(true)
  panel:RegisterForDrag("LeftButton")
  panel:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  GJ.ApplyPanelStyle()
  panel.icon = panel:CreateTexture(nil, "ARTWORK")
  panel.icon:SetSize(16, 16)
  panel.icon:SetPoint("BOTTOMLEFT", 5, (PANEL_ROW_HEIGHT - 16) / 2)
  panel.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  panel.text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  panel.text:SetPoint("LEFT", panel.icon, "RIGHT", 5, 0)
  panel.text:SetPoint("RIGHT", -5, 0)
  panel.text:SetJustifyH("LEFT")
  panel.text:SetWordWrap(false)
  panel:SetScript("OnDragStart", function(self) if not db.Locked then self:StartMoving() end end)
  panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
  panel:SetScript("OnClick", OnClick)
  panel:SetScript("OnEnter", function() GJ.StartPreview(); GJ.ShowPanelTooltip() end)
  -- OnLeave runs BEFORE the client updates mouse focus, so IsMouseOver() is still true inside
  -- it; a synchronous Refresh would keep the hover row. Defer one frame so the gate re-applies.
  panel:SetScript("OnLeave", function() GJ.HidePanelTooltip(); C_Timer.After(0, GJ.Refresh) end)
  RestorePosition()
  return panel
end

-- ---------------------------------------------------------------------------
-- refresh both displays from the current scan
-- ---------------------------------------------------------------------------
function GJ.Refresh()
  local w = GJ.Worst()
  local pending = GJ.AutoDrop_Pending()
  -- Display gate: the worst slot is only surfaced once bags are getting tight; the
  -- tooltip/status keep the full list regardless. The login preview only forces the
  -- *panel* visible (showing "no eligible junk"). While the mouse is OVER the panel the
  -- gate is lifted so the row shows exactly what a click would destroy.
  local previewing = GetTime() < (GJ.PreviewUntil or 0)
  local hovering = panel and panel:IsMouseOver()
  if w and not hovering and GJ.FreeSlots >= (db.ShowWhenFreeBelow or 0) then w = nil end
  local text
  if w then
    text = string.format("%sx%d - %s|r %s", pending and "|cffff4040" or COLOR, w.count, FormatMoney(w.value), w.link or w.name)
  end
  if ldbObject then
    ldbObject.icon = w and w.icon or ADDON_ICON
    ldbObject.text = w and string.format("%sx%d %s|r %s", pending and "|cffff4040" or "", w.count, FormatMoney(w.value), w.name) or "no junk"
  end
  if db.ShowPanel then
    CreatePanel()
    if w or previewing or not db.AutoHide then
      panel.icon:SetTexture(w and w.icon or ADDON_ICON)
      panel.icon:SetDesaturated(not w)   -- grey bag when there is nothing to drop
      panel.text:SetText(text or (COLOR .. "no eligible junk to drop|r"))
      local rowWidth = 16 + 5 + panel.text:GetStringWidth()   -- icon + gap + text
      local dotsWidth, dotsHeight = UpdateDots()
      local panelWidth = math.max(120, math.min(400, math.max(rowWidth + 20, dotsWidth)))
      panel:SetWidth(panelWidth)
      panel:SetHeight(PANEL_ROW_HEIGHT + dotsHeight)
      -- Centre the icon+text row under the dots; clamp the text so it can't run off the right edge.
      local rowLeft = math.max(5, (panelWidth - rowWidth) / 2)
      panel.icon:ClearAllPoints()
      panel.icon:SetPoint("BOTTOMLEFT", rowLeft, (PANEL_ROW_HEIGHT - 16) / 2)
      panel:Show()
    else
      panel:Hide()
    end
  elseif panel then
    panel:Hide()
  end
end

-- ---------------------------------------------------------------------------
-- options
-- ---------------------------------------------------------------------------
local optionsCategory, optionsFrame

local function CreateOptions()
  optionsFrame = CreateFrame("Frame", "GotJunkOptions")
  optionsFrame.name = "GotJunk"

  -- Scrolling container: the registered canvas holds a ScrollFrame whose child `content`
  -- carries every widget. Mouse wheel scrolls; a standard scrollbar sits on the right.
  local scroll = CreateFrame("ScrollFrame", "GotJunkOptionsScroll", optionsFrame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -4)
  scroll:SetPoint("BOTTOMRIGHT", -28, 4)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(620, 1200)   -- height is corrected in Update once widgets exist
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(self, w) content:SetWidth(math.max(620, w)) end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = self:GetVerticalScrollRange()
    self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 40)))
  end)

  local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16); title:SetText("GotJunk")
  local sub = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6); sub:SetWidth(560); sub:SetJustifyH("LEFT")
  sub:SetText("Shows the least valuable grey/white slot in your bags. Left-click it to destroy it. Auto-drop destroys that slot on your next loot click when fewer than the chosen number of bag slots are free. When both thresholds are ticked, both must be true.")

  -- Layout grid: every widget hangs off `last` at a fixed left column; sections are bordered
  -- boxes with a header. Keeps checkboxes, radios and sliders on one vertical line.
  local BOX_W, PAD = 580, 10
  local last, lastDy = sub, -14
  local function Place(w, dy, dx) w:SetPoint("TOPLEFT", last, "BOTTOMLEFT", dx or 0, dy or lastDy); last = w; lastDy = -6 end

  local function Check(parent, key, label, tip)
    local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    cb.Text:SetText(label)
    cb.tooltipText = tip
    cb:SetScript("OnClick", function(self) db[key] = self:GetChecked() and true or false; GJ.OnOptionChanged(key) end)
    cb.Update = function(self) self:SetChecked(db[key] and true or false) end
    return cb
  end

  -- Slider with its label above-left (not centred over the track) so it aligns with checkboxes.
  local function Slider(parent, name, key, default, minV, maxV, labelFn, onChange)
    local holder = CreateFrame("Frame", nil, parent); holder:SetSize(BOX_W - 2 * PAD, 44)
    local label = holder:CreateFontString(nil, "ARTWORK", "GameFontHighlight"); label:SetPoint("TOPLEFT", 4, 0)
    local s = CreateFrame("Slider", name, holder, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 2, -6); s:SetWidth(220)
    s:SetMinMaxValues(minV, maxV); s:SetValueStep(1); s:SetObeyStepOnDrag(true)
    _G[name .. "Low"]:SetText(tostring(minV)); _G[name .. "High"]:SetText(tostring(maxV)); _G[name .. "Text"]:SetText("")
    s:SetScript("OnValueChanged", function(self, v) v = math.floor(v + 0.5); db[key] = v; label:SetText(labelFn(v)); onChange() end)
    holder.Update = function() s:SetValue(db[key] or default); label:SetText(labelFn(db[key] or default)) end
    return holder
  end

  -- Bordered section. Children are laid out inside with their own `last` chain; the box is
  -- sized from the running height after the children are added.
  local function Section(header)
    local box = CreateFrame("Frame", nil, content, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetWidth(BOX_W)
    if box.SetBackdrop then
      box:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
      box:SetBackdropColor(0, 0, 0, 0.25); box:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.6)
    end
    local h = box:CreateFontString(nil, "ARTWORK", "GameFontNormal"); h:SetPoint("TOPLEFT", PAD, -PAD); h:SetText(header)
    box.inner_last, box.inner_h = h, PAD + 14
    function box:Add(w, height, dy, dx)
      dy = dy or -6
      w:SetPoint("TOPLEFT", self.inner_last, "BOTTOMLEFT", dx or 0, dy)
      if dx and dx ~= 0 then w.__dx = dx end
      self.inner_last, self.inner_h = w, self.inner_h - dy + height
      return w
    end
    function box:Finish() self:SetHeight(self.inner_h + PAD) end
    Place(box, -14)
    return box
  end

  -- Auto-hide first, directly under the intro (handy to turn off for testing).
  Place(Check(content, "AutoHide", "Auto-hide panel when no eligible junk", "Untick to keep the panel (and its bag dots) visible at all times."), -14)

  -- Section: Display
  local disp = Section("Display")
  disp:Add(Check(disp, "ShowPanel", "Show standalone panel", "Off by default when a LibDataBroker display (ChocolateBar, Titan...) is present."), 26)
  disp:Add(Check(disp, "Locked", "Lock panel position"), 26)
  local c5 = disp:Add(Check(disp, "MinimapHide", "Hide minimap button"), 26)
  c5:SetScript("OnClick", function(self) db.Minimap.hide = self:GetChecked() and true or false; GJ.OnOptionChanged("MinimapHide") end)
  c5.Update = function(self) self:SetChecked(db.Minimap.hide and true or false) end
  disp:Add(Slider(disp, "GotJunkOptionsShowWhen", "ShowWhenFreeBelow", 3, 0, 20,
    function(v) return "Show junk when fewer than " .. v .. " slots free (0 = never)" end, GJ.Refresh), 44, -10)
  disp:Finish()

  -- Section: Visual style (radio group)
  local vs = Section("Visual style")
  local styleRadios = {}
  local function StyleRadio(style, label)
    local r = CreateFrame("CheckButton", nil, vs, "UIRadioButtonTemplate"); r:SetSize(16, 16)
    r.text = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"); r.text:SetPoint("LEFT", r, "RIGHT", 4, 0); r.text:SetText(label)
    r:SetScript("OnClick", function() db.Style = style; for _, o in ipairs(styleRadios) do o:SetChecked(o.style == style) end; GJ.ApplyPanelStyle(); GJ.Refresh() end)
    r.style = style; r.Update = function(self) self:SetChecked((db.Style or "classic") == style) end
    styleRadios[#styleRadios + 1] = r; return vs:Add(r, 16, -6, 0)
  end
  StyleRadio("classic", "Classic rounded border"); StyleRadio("flat", "Modern flat")
  vs:Finish()

  -- Section: Auto-drop thresholds
  local ad = Section("Auto-drop thresholds")
  ad:Add(Slider(ad, "GotJunkOptionsKeepClear", "KeepClearSlots", 1, 0, 10,
    function(v) return "Slots to keep clear: " .. v end, GJ.Refresh), 44)
  ad:Add(Check(ad, "AutoDrop_Below10c", "Auto-drop below 10c slot max", "Destroy the worst slot only if its whole stack is worth less than 10 copper."), 26, -8)
  ad:Add(Check(ad, "AutoDrop_Below2Pct", "Auto-drop below 2% of all bag junk value", "Destroy the worst slot only if it is worth less than 2% of all grey/white junk in your bags."), 26)
  ad:Finish()

  -- Section: Food and water (radio group, straight column)
  local fw = Section("Food and water")
  local radios = {}
  local function Radio(mode, label, tip)
    local r = CreateFrame("CheckButton", nil, fw, "UIRadioButtonTemplate")
    r:SetSize(16, 16)
    r.text = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"); r.text:SetPoint("LEFT", r, "RIGHT", 4, 0); r.text:SetText(label)
    r.tooltipText = tip
    r:SetScript("OnClick", function() db.FoodWaterMode = mode; for _, o in ipairs(radios) do o:SetChecked(o.mode == mode) end; GJ.Scan() end)
    r.mode = mode
    r.Update = function(self) self:SetChecked(db.FoodWaterMode == mode) end
    radios[#radios + 1] = r
    return fw:Add(r, 16, -6, 0)
  end
  Radio("never", "Never junk food or water")
  Radio("lowlevel", "Only junk low-level food and water (required level 10+ below yours)", "Vendor food/water tiers unlock every ~10 levels; once the next tier is available the old one is junk.")
  fw:Add(Check(fw, "FoodWater_ExcessNonBuff", "Junk usable excess non-buff food/water", "Among food and water that is still level-appropriate and grants no Well Fed buff, keep the fullest N stacks of each item; any further stacks are junk."), 26, -10)
  fw:Add(Slider(fw, "GotJunkOptionsFoodStacks", "FoodWaterKeepStacks", 3, 0, 10,
    function(v) return "Stacks to keep: " .. v end, GJ.Scan), 44, -2, 24)
  fw:Add(Check(fw, "FoodWater_LowLevelBuffEligible", "Low-level buff food is junk eligible", "Well Fed food whose required level is 10+ below yours."), 26, -8, -24)
  fw:Add(Check(fw, "FoodWater_OffClassBuffEligible", "Off-class buff food is junk eligible", "Well Fed food whose stats do nothing for your class (e.g. Strength food on a Mage). Stamina-only food is never off-class."), 26)
  fw:Finish()

  -- Section: Protected items (built in ProtectUI.lua; returns the frame that ends the layout)
  local protSection = Section("Protected items")
  local protBottom = GJ.ProtectUI_Build(protSection, BOX_W - 2 * PAD)
  protSection:Add(protBottom, protBottom:GetHeight(), -4)
  protSection:Finish()
  -- The protected section grows/shrinks (per-char box, list sizes); resize it and the scroll
  -- content whenever the UI re-renders.
  local protBaseH = protSection.inner_h - protBottom:GetHeight()
  GJ.OptionsLayoutChanged = function()
    protSection.inner_h = protBaseH + protBottom:GetHeight()
    protSection:Finish()
    local top, bottom = content:GetTop(), protSection:GetBottom()
    if top and bottom then content:SetHeight(top - bottom + 24) end
  end

  -- Content height = bottom of the last widget; give the scroll frame something to scroll.
  local function LayoutContentHeight()
    local top, bottom = content:GetTop(), protSection:GetBottom()
    if top and bottom then content:SetHeight(top - bottom + 24) end
  end

  -- Walk nested children so widgets inside section boxes get refreshed too.
  local function UpdateTree(frame)
    for _, child in ipairs({ frame:GetChildren() }) do
      if child.Update then child:Update() end
      UpdateTree(child)
    end
  end
  optionsFrame.Update = function(self)
    UpdateTree(content)
    if GJ.ProtectUI_Refresh then GJ.ProtectUI_Refresh() end
    LayoutContentHeight()
  end
  optionsFrame:SetScript("OnShow", optionsFrame.Update)

  if Settings and Settings.RegisterCanvasLayoutCategory then
    optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsFrame, "GotJunk")
    Settings.RegisterAddOnCategory(optionsCategory)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(optionsFrame)
  end
end

function GJ.OnOptionChanged(key)
  if key == "MinimapHide" and DBIcon then
    if db.Minimap.hide then DBIcon:Hide("GotJunk") else DBIcon:Show("GotJunk") end
  end
  if key:find("^FoodWater") then GJ.Scan() else GJ.Refresh() end
end

function GJ.OpenOptions()
  if Settings and Settings.OpenToCategory and optionsCategory then Settings.OpenToCategory(optionsCategory:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then InterfaceOptionsFrame_OpenToCategory(optionsFrame); InterfaceOptionsFrame_OpenToCategory(optionsFrame) end
end

-- ---------------------------------------------------------------------------
-- slash
-- ---------------------------------------------------------------------------
local function Slash(msg)
  msg = (msg or ""):match("^%s*(.-)%s*$")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()
  if cmd == "" then db.ShowPanel = not db.ShowPanel; GJ.Refresh(); Print("panel %s", db.ShowPanel and "shown" or "hidden")
  elseif cmd == "options" or cmd == "config" or cmd == "settings" then GJ.OpenOptions()
  elseif cmd == "lock" then db.Locked = not db.Locked; Print("panel %s", db.Locked and "locked" or "unlocked")
  elseif cmd == "reset" then db.Position = nil; if panel then RestorePosition() end; Print("panel position reset")
  elseif cmd == "drop" then if not GJ.DropWorst("slash") then Print("nothing dropped (needs a hardware event, e.g. a keybound macro)") end
  elseif cmd == "scan" then GJ.Scan(); Print("%d junk slots, total %s, %d free slots", #GJ.JunkSlots, FormatMoney(GJ.Junk_TotalValue), GJ.FreeSlots)
  elseif cmd == "tipdebug" then GJ.TipDebug = not GJ.TipDebug; Print("tooltip debug %s - hover the panel and read chat", GJ.TipDebug and "ON" or "off")
  elseif cmd == "protect" then
    local sub, arg = rest:match("^(%S*)%s*(.-)$")
    if sub == "list" or sub == "" then
      local function dump(label, t)
        local n = 0
        for id in pairs(t) do n = n + 1; local _, link = GetItemInfo(id); print(string.format("  [%s] %s", label, link or ("item:" .. id))) end
        return n
      end
      local total = 0
      if db.UsePerCharacter then total = total + dump("character", GotJunkCharDB.Protect) end
      total = total + dump("account", db.Protect)
      for id in pairs(GJ.BuiltinProtect or {}) do if not db.BuiltinRemoved[id] then total = total + 1; local _, link = GetItemInfo(id); print("  [built-in] " .. (link or ("item:" .. id))) end end
      Print("%d protected item(s). Usage: /gotjunk protect [account|character] <itemlink|itemID>", total)
    else
      local tier
      if sub == "account" or sub == "character" then tier = sub; rest = arg end
      local id = tonumber(rest) or tonumber(rest:match("item:(%d+)"))
      if not id then Print("could not read an item from '%s'", rest)
      elseif tier then GJ.ProtectAdd(id, tier)
      else GJ.ToggleProtect(id) end
    end
  elseif cmd == "status" then
    local version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON_NAME, "Version")
    Print("version %s | %d junk slots (%s) | free %d / keep %d | below10c %s | below2%% %s | pending %s | panel %s",
      tostring(version), #GJ.JunkSlots, FormatMoney(GJ.Junk_TotalValue), GJ.FreeSlots, db.KeepClearSlots,
      tostring(db.AutoDrop_Below10c), tostring(db.AutoDrop_Below2Pct), tostring(GJ.AutoDrop_Pending()), tostring(db.ShowPanel))
  else
    Print("/gotjunk - toggle panel | options | lock | reset | drop | scan | protect [itemlink|list] | status")
  end
end

-- ---------------------------------------------------------------------------
-- init / events
-- ---------------------------------------------------------------------------
local function InitDB()
  if type(GotJunkDB) ~= "table" then GotJunkDB = {} end
  db = GotJunkDB
  db.Version = db.Version or DB_VERSION
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil and v ~= nil then
      if type(v) == "table" then db[k] = {} for kk, vv in pairs(v) do db[k][kk] = vv end else db[k] = v end
    end
  end
  GJ.db = db
  -- migration: the old "stacks" radio became the excess checkbox under the "lowlevel" radio
  if db.FoodWaterMode == "stacks" then db.FoodWaterMode = "lowlevel"; db.FoodWater_ExcessNonBuff = true end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    InitDB()
    SLASH_GOTJUNK1 = "/gotjunk"
    SlashCmdList.GOTJUNK = Slash
    SetupLDB()
    CreateOptions()
  elseif event == "PLAYER_LOGIN" then
    if db.ShowPanel == nil then
      db.ShowPanel = not HasLDBHost()
      Print("first run: standalone panel %s (%s). /gotjunk to toggle, /gotjunk options for settings.", db.ShowPanel and "shown" or "hidden", db.ShowPanel and "no LDB display found" or "LDB display found")
    end
    GJ.StartPreview()  -- show the panel for a while at login so the player can find / move it
    HookLootButtons()
    f:RegisterEvent("BAG_UPDATE_DELAYED")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:RegisterEvent("LOOT_OPENED")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    GJ.Scan()
  elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_ENTERING_WORLD" then
    GJ.Scan()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if GJ.Scan_Incomplete then GJ.Scan() end
  elseif event == "LOOT_OPENED" then
    HookLootButtons()
  end
end)
