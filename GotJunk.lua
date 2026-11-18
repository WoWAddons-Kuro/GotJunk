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
local COLOR = "|cff9d9d9d"   -- poor-quality grey for the prefix

local DEFAULTS = {
  KeepClearSlots = 1,
  AutoDrop_Below10c = false,
  AutoDrop_Below2Pct = false,
  ShowPanel = nil,      -- decided on first login: false if an LDB display host is present
  Locked = false,
  Position = nil,       -- { point, x, y }
  Minimap = { hide = false },
  Protect = {},         -- [itemID] = true
}

local db

-- ---------------------------------------------------------------------------
-- utils / API shims (Era 1.15 and Forever 16001 both expose C_Container; keep fallbacks)
-- ---------------------------------------------------------------------------
local function Print(fmt, ...) print("|cffb0b0b0GotJunk|r: " .. string.format(fmt, ...)) end

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
  if g > 0 then return string.format("%dg %ds %dc", g, s, c) end
  if s > 0 then return string.format("%ds %dc", s, c) end
  return string.format("%dc", c)
end

-- ---------------------------------------------------------------------------
-- scan: build the ranked junk list
-- ---------------------------------------------------------------------------
GJ.JunkSlots = {}        -- ascending by value: { bag, slot, itemID, name, link, icon, count, price, value, quality }
GJ.Junk_TotalValue = 0
GJ.FreeSlots = 0
GJ.Scan_Incomplete = false  -- some item info was not cached; rescan on GET_ITEM_INFO_RECEIVED

local function IsJunkCandidate(itemID, noValue, containerQuality)
  if not itemID or noValue or itemID == HEARTHSTONE_ID or db.Protect[itemID] then return false end
  local name, link, quality, _, _, _, _, _, _, icon, price, classID = GetItemInfo(itemID)
  if not name then return nil end  -- not cached yet
  quality = quality or containerQuality
  if quality == nil or quality > 1 then return false end
  if not price or price <= 0 then return false end
  if classID == QUEST_CLASS_ID then return false end
  return true, name, link, quality, icon, price
end

function GJ.Scan()
  local list, total, free, incomplete = {}, 0, 0, false
  for bag = 0, NUM_BAGS do
    local n = GetContainerNumSlots(bag) or 0
    if n > 0 then
      local f, family = GetContainerNumFreeSlots(bag)
      if (family or 0) == 0 then free = free + (f or 0) end
      for slot = 1, n do
        local itemID, count, locked, noValue, cq, tex = GetSlotInfo(bag, slot)
        if itemID and not locked then
          local ok, name, link, quality, icon, price = IsJunkCandidate(itemID, noValue, cq)
          if ok == nil then incomplete = true
          elseif ok then
            local value = price * (count or 1)
            total = total + value
            list[#list + 1] = { bag = bag, slot = slot, itemID = itemID, name = name, link = link,
              icon = icon or tex, count = count or 1, price = price, value = value, quality = quality }
          end
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.value ~= b.value then return a.value < b.value end
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    if a.bag ~= b.bag then return a.bag < b.bag end
    return a.slot < b.slot
  end)
  GJ.JunkSlots, GJ.Junk_TotalValue, GJ.FreeSlots, GJ.Scan_Incomplete = list, total, free, incomplete
  GJ.Refresh()
end

function GJ.Worst() return GJ.JunkSlots[1] end

-- Is the auto-drop condition met for the worst slot right now? (AND of ticked boxes)
function GJ.AutoDrop_Pending()
  local w = GJ.Worst()
  if not w then return false end
  if GJ.FreeSlots >= (db.KeepClearSlots or 0) then return false end
  if not (db.AutoDrop_Below10c or db.AutoDrop_Below2Pct) then return false end
  if db.AutoDrop_Below10c and not (w.value < 10) then return false end
  if db.AutoDrop_Below2Pct and not (w.value < 0.02 * GJ.Junk_TotalValue) then return false end
  return true
end

-- ---------------------------------------------------------------------------
-- destroy (must be called from a hardware event handler)
-- ---------------------------------------------------------------------------
function GJ.DropWorst(reason)
  local w = GJ.Worst()
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
  return true
end

function GJ.ToggleProtect(itemID)
  if not itemID then return end
  if db.Protect[itemID] then db.Protect[itemID] = nil; Print("unprotected item %d", itemID)
  else db.Protect[itemID] = true; local _, link = GetItemInfo(itemID); Print("protected %s", link or itemID) end
  GJ.Scan()
end

-- ---------------------------------------------------------------------------
-- loot hook: OnMouseDown on loot buttons runs before the loot OnClick and is a hardware event
-- ---------------------------------------------------------------------------
local function OnLootMouseDown()
  if GJ.AutoDrop_Pending() then GJ.DropWorst("auto-drop on loot") end
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

local function OnClick(_, button)
  if button == "RightButton" then
    if IsShiftKeyDown() then local w = GJ.Worst(); if w then GJ.ToggleProtect(w.itemID) end
    else GJ.OpenOptions() end
  else
    GJ.DropWorst()
  end
end

local function OnTooltipShow(tt)
  tt:AddLine("GotJunk")
  if #GJ.JunkSlots == 0 then
    tt:AddLine("No junk in bags", 0.7, 0.7, 0.7)
  else
    for i = 1, math.min(5, #GJ.JunkSlots) do
      local j = GJ.JunkSlots[i]
      tt:AddDoubleLine(string.format("|T%s:14|t %s x%d", tostring(j.icon), j.link or j.name, j.count), FormatMoney(j.value), 1, 1, 1, 1, 0.82, 0)
    end
    tt:AddDoubleLine(string.format("%d junk slots total", #GJ.JunkSlots), FormatMoney(GJ.Junk_TotalValue), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
  end
  tt:AddDoubleLine("Free slots", tostring(GJ.FreeSlots) .. " (keep " .. tostring(db.KeepClearSlots) .. " clear)", 0.7, 0.7, 0.7, 1, 1, 1)
  if db.AutoDrop_Below10c or db.AutoDrop_Below2Pct then
    tt:AddLine(GJ.AutoDrop_Pending() and "|cffff4040Auto-drop pending: next loot click destroys the worst slot|r" or "|cff60ff60Auto-drop armed|r")
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
local panel

local function SavePosition()
  local point, _, _, x, y = panel:GetPoint(1)
  db.Position = { point, x, y }
end

local function RestorePosition()
  panel:ClearAllPoints()
  if db.Position then panel:SetPoint(db.Position[1], UIParent, db.Position[1], db.Position[2], db.Position[3])
  else panel:SetPoint("TOP", UIParent, "TOP", 0, -120) end
end

local function CreatePanel()
  if panel then return panel end
  panel = CreateFrame("Button", "GotJunkPanel", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  panel:SetSize(220, 24)
  panel:SetFrameStrata("MEDIUM")
  panel:SetClampedToScreen(true)
  panel:SetMovable(true)
  panel:RegisterForDrag("LeftButton")
  panel:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  if panel.SetBackdrop then
    panel:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    panel:SetBackdropColor(0, 0, 0, 0.6)
    panel:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
  end
  panel.icon = panel:CreateTexture(nil, "ARTWORK")
  panel.icon:SetSize(16, 16)
  panel.icon:SetPoint("LEFT", 5, 0)
  panel.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  panel.text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  panel.text:SetPoint("LEFT", panel.icon, "RIGHT", 5, 0)
  panel.text:SetPoint("RIGHT", -5, 0)
  panel.text:SetJustifyH("LEFT")
  panel.text:SetWordWrap(false)
  panel:SetScript("OnDragStart", function(self) if not db.Locked then self:StartMoving() end end)
  panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
  panel:SetScript("OnClick", OnClick)
  panel:SetScript("OnEnter", function(self)
    -- Anchor to the side of the panel with the most screen room so the tooltip never covers it.
    local _, cy = self:GetCenter()
    local screenH = UIParent:GetHeight()
    local below = cy and cy > screenH / 2
    GameTooltip:SetOwner(self, below and "ANCHOR_BOTTOM" or "ANCHOR_TOP")
    OnTooltipShow(GameTooltip)
    if not db.Locked then GameTooltip:AddLine("Drag to move  (/gotjunk lock)", 0.5, 0.5, 0.5) end
    GameTooltip:Show()
  end)
  panel:SetScript("OnLeave", function() GameTooltip:Hide() end)
  RestorePosition()
  return panel
end

-- ---------------------------------------------------------------------------
-- refresh both displays from the current scan
-- ---------------------------------------------------------------------------
function GJ.Refresh()
  local w = GJ.Worst()
  local pending = GJ.AutoDrop_Pending()
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
    if w then
      panel.icon:SetTexture(w.icon)
      panel.text:SetText(text)
      local width = panel.text:GetStringWidth() + 16 + 20
      panel:SetWidth(math.max(120, math.min(400, width)))
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
  local title = optionsFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16); title:SetText("GotJunk")
  local sub = optionsFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6); sub:SetWidth(560); sub:SetJustifyH("LEFT")
  sub:SetText("Shows the least valuable grey/white slot in your bags. Left-click it to destroy it. Auto-drop destroys that slot on your next loot click when fewer than the chosen number of bag slots are free. When both thresholds are ticked, both must be true.")

  local last = sub
  local function Check(key, label, tip)
    local cb = CreateFrame("CheckButton", nil, optionsFrame, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -8)
    cb.Text:SetText(label)
    cb.tooltipText = tip
    cb:SetScript("OnClick", function(self) db[key] = self:GetChecked() and true or false; GJ.OnOptionChanged(key) end)
    cb.Update = function(self) self:SetChecked(db[key] and true or false) end
    last = cb
    return cb
  end

  -- Slots to keep clear (slider)
  local slider = CreateFrame("Slider", "GotJunkOptionsKeepClear", optionsFrame, "OptionsSliderTemplate")
  slider:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 8, -40)
  slider:SetWidth(220); slider:SetMinMaxValues(0, 10); slider:SetValueStep(1); slider:SetObeyStepOnDrag(true)
  _G[slider:GetName() .. "Low"]:SetText("0"); _G[slider:GetName() .. "High"]:SetText("10")
  slider.Text = _G[slider:GetName() .. "Text"]
  slider:SetScript("OnValueChanged", function(self, v)
    v = math.floor(v + 0.5); db.KeepClearSlots = v
    self.Text:SetText("Auto-drop thresholds: slots to keep clear: " .. v); GJ.Refresh()
  end)
  slider.Update = function(self) self:SetValue(db.KeepClearSlots or 1); self.Text:SetText("Auto-drop thresholds: slots to keep clear: " .. (db.KeepClearSlots or 1)) end
  last = slider

  local c1 = Check("AutoDrop_Below10c", "Auto-drop below 10c slot max", "Destroy the worst slot only if its whole stack is worth less than 10 copper.")
  c1:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", -8, -12)
  local c2 = Check("AutoDrop_Below2Pct", "Auto-drop below 2% of all bag junk value", "Destroy the worst slot only if it is worth less than 2% of all grey/white junk in your bags.")
  local c3 = Check("ShowPanel", "Show standalone panel", "Off by default when a LibDataBroker display (ChocolateBar, Titan...) is present.")
  c3:SetPoint("TOPLEFT", c2, "BOTTOMLEFT", 0, -20)
  Check("Locked", "Lock panel position")
  local c5 = Check("MinimapHide", "Hide minimap button")
  c5:SetScript("OnClick", function(self) db.Minimap.hide = self:GetChecked() and true or false; GJ.OnOptionChanged("MinimapHide") end)
  c5.Update = function(self) self:SetChecked(db.Minimap.hide and true or false) end

  local prot = optionsFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  prot:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -20); prot:SetWidth(560); prot:SetJustifyH("LEFT")
  local clear = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
  clear:SetSize(140, 22); clear:SetPoint("TOPLEFT", prot, "BOTTOMLEFT", 0, -6); clear:SetText("Clear protected list")
  clear:SetScript("OnClick", function() wipe(db.Protect); GJ.Scan(); optionsFrame:Update() end)

  optionsFrame.Update = function(self)
    for _, child in ipairs({ self:GetChildren() }) do if child.Update then child:Update() end end
    local n, names = 0, {}
    for id in pairs(db.Protect) do n = n + 1; local _, link = GetItemInfo(id); names[#names + 1] = link or tostring(id) end
    prot:SetText(n == 0 and "Protected items: none (shift-right-click the display, or /gotjunk protect <itemlink>)" or ("Protected items (" .. n .. "): " .. table.concat(names, "  ")))
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
  GJ.Refresh()
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
  elseif cmd == "protect" then
    if rest == "list" or rest == "" then
      local n = 0
      for id in pairs(db.Protect) do n = n + 1; local _, link = GetItemInfo(id); print("  " .. (link or tostring(id))) end
      Print("%d protected item(s). Usage: /gotjunk protect <itemlink|itemID>", n)
    else
      local id = tonumber(rest) or tonumber(rest:match("item:(%d+)"))
      if id then GJ.ToggleProtect(id) else Print("could not read an item from '%s'", rest) end
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
      Print("first run: standalone panel %s (%s). /gj to toggle, /gj options for settings.", db.ShowPanel and "shown" or "hidden", db.ShowPanel and "no LDB display found" or "LDB display found")
    end
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
