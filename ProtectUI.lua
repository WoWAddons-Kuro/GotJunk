-- Protected-items UI: three stacked list boxes (character / account / built-in) with
-- Delete / Promote / Demote / Restore row buttons, a Copy-list frame and an Add row.
-- Built inside the options page by GJ.ProtectUI_Build(parentSection, width); returns the
-- frame whose bottom edge ends the section. GJ.ProtectUI_Refresh() re-renders rows.
local _, GJ = ...

local GetItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

local ROW_H, ROWS_VISIBLE, BTN_W = 20, 6, 64
local TIERS = {
  { key = "character", label = "Character",  perCharOnly = true },
  { key = "account",   label = "Account" },
  { key = "builtin",   label = "Built-in" },
}

local db
local boxes = {}      -- tierKey -> box frame
local root            -- container frame returned to the options page
local perCharCheck
local addBox, addAccountBtn, addCharBtn
local copyFrame

-- ---------------------------------------------------------------------------
-- data access
-- ---------------------------------------------------------------------------
local function CharProtect() return GotJunkCharDB and GotJunkCharDB.Protect or {} end

-- Sorted array of { id, removed } for a tier.
local function TierItems(tierKey)
  local out = {}
  if tierKey == "character" then for id in pairs(CharProtect()) do out[#out + 1] = { id = id } end
  elseif tierKey == "account" then for id in pairs(db.Protect) do out[#out + 1] = { id = id } end
  else for id in pairs(GJ.BuiltinProtect or {}) do out[#out + 1] = { id = id, removed = db.BuiltinRemoved[id] and true or false } end end
  table.sort(out, function(a, b)
    local na, nb = GetItemInfo(a.id), GetItemInfo(b.id)
    if na and nb and na ~= nb then return na < nb end
    if na and not nb then return true end
    if nb and not na then return false end
    return a.id < b.id
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- copy frame: one line per item  "itemID<TAB>Item Name", pre-selected for Ctrl-C
-- ---------------------------------------------------------------------------
local function ShowCopyFrame(title, items)
  if not copyFrame then
    copyFrame = CreateFrame("Frame", "GotJunkCopyFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    copyFrame:SetSize(420, 300)
    copyFrame:SetPoint("CENTER")
    copyFrame:SetFrameStrata("DIALOG")
    copyFrame:SetMovable(true); copyFrame:EnableMouse(true)
    copyFrame:RegisterForDrag("LeftButton")
    copyFrame:SetScript("OnDragStart", copyFrame.StartMoving)
    copyFrame:SetScript("OnDragStop", copyFrame.StopMovingOrSizing)
    if copyFrame.SetBackdrop then
      copyFrame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    end
    copyFrame.title = copyFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    copyFrame.title:SetPoint("TOP", 0, -16)
    local hint = copyFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOP", copyFrame.title, "BOTTOM", 0, -4)
    hint:SetText("Text is selected - press Ctrl-C to copy. One line per item: itemID, name.")
    local scroll = CreateFrame("ScrollFrame", "GotJunkCopyScroll", copyFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -56); scroll:SetPoint("BOTTOMRIGHT", -40, 44)
    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(340)
    eb:SetScript("OnEscapePressed", function() copyFrame:Hide() end)
    -- Read-only: any edit is reverted so the hand-off text stays exact.
    eb:SetScript("OnTextChanged", function(self, userInput) if userInput then self:SetText(copyFrame.text or ""); self:HighlightText() end end)
    scroll:SetScrollChild(eb)
    copyFrame.editBox = eb
    local close = CreateFrame("Button", nil, copyFrame, "UIPanelButtonTemplate")
    close:SetSize(80, 22); close:SetPoint("BOTTOM", 0, 16); close:SetText(CLOSE)
    close:SetScript("OnClick", function() copyFrame:Hide() end)
    tinsert(UISpecialFrames, "GotJunkCopyFrame")
  end
  local lines = {}
  for _, it in ipairs(items) do
    local name = GetItemInfo(it.id)
    lines[#lines + 1] = string.format("%d\t%s%s", it.id, name or "", it.removed and "\t(removed)" or "")
  end
  copyFrame.text = table.concat(lines, "\n")
  copyFrame.title:SetText(title)
  copyFrame.editBox:SetText(copyFrame.text)
  copyFrame:Show()
  copyFrame.editBox:SetFocus()
  copyFrame.editBox:HighlightText()
end

-- ---------------------------------------------------------------------------
-- one list box
-- ---------------------------------------------------------------------------
local function CreateBox(parent, tier, width)
  local box = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  box:SetSize(width, 20 + ROW_H * ROWS_VISIBLE + 8)
  box.tier = tier
  if box.SetBackdrop then
    box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    box:SetBackdropColor(0, 0, 0, 0.3); box:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
  end
  box.header = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  box.header:SetPoint("TOPLEFT", 8, -5)

  local x = -6
  local function HeaderButton(text, w, onClick)
    local b = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    b:SetSize(w, 18); b:SetPoint("TOPRIGHT", x, -3); b:SetText(text); b:SetScript("OnClick", onClick)
    b:SetNormalFontObject(GameFontHighlightSmall); b:SetHighlightFontObject(GameFontNormalSmall); b:SetDisabledFontObject(GameFontDisableSmall)
    x = x - w - 4
    return b
  end
  HeaderButton("Copy list", 70, function() ShowCopyFrame("GotJunk - " .. tier.label .. " protected list", TierItems(tier.key)) end)
  if tier.key == "builtin" then
    HeaderButton("Restore all", 76, function() GJ.ProtectRestoreBuiltin(nil) end)
  else
    HeaderButton("Clear", 48, function()
      local t = tier.key == "character" and CharProtect() or db.Protect
      wipe(t); GJ.Scan(); GJ.ProtectUI_Refresh()
    end)
  end

  local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 4, -22); scroll:SetPoint("BOTTOMRIGHT", -26, 4)
  local listFrame = CreateFrame("Frame", nil, scroll)
  listFrame:SetSize(width - 30, ROW_H)
  scroll:SetScrollChild(listFrame)
  box.scroll, box.listFrame, box.rows = scroll, listFrame, {}

  box.empty = listFrame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  box.empty:SetPoint("TOPLEFT", 6, -4)
  return box
end

local function AcquireRow(box, i)
  local row = box.rows[i]
  if row then return row end
  row = CreateFrame("Button", nil, box.listFrame)
  row:SetSize(box.listFrame:GetWidth(), ROW_H)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(16, 16); row.icon:SetPoint("LEFT", 4, 0)
  row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row.icon, "RIGHT", 5, 0); row.text:SetJustifyH("LEFT"); row.text:SetWordWrap(false)
  row.text:SetPoint("RIGHT", row, "RIGHT", -(BTN_W * 2 + 12), 0)
  local function Btn(anchorX, w)
    local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    b:SetSize(w or BTN_W, ROW_H - 2); b:SetPoint("RIGHT", anchorX, 0)
    b:SetNormalFontObject(GameFontHighlightSmall); b:SetHighlightFontObject(GameFontNormalSmall); b:SetDisabledFontObject(GameFontDisableSmall)
    return b
  end
  row.btnB = Btn(-2)              -- rightmost: Delete / Restore
  row.btnA = Btn(-2 - BTN_W - 4)  -- left of it: Promote / Demote
  row:SetScript("OnEnter", function(self)
    if not self.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local _, link = GetItemInfo(self.itemID)
    if link then GameTooltip:SetHyperlink(link) else GameTooltip:SetText("item:" .. self.itemID) end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  box.rows[i] = row
  return row
end

local function RenderBox(box)
  local tier = box.tier
  local items = TierItems(tier.key)
  local live = 0
  for _, it in ipairs(items) do if not it.removed then live = live + 1 end end
  box.header:SetText(string.format("%s (%d)", tier.label, live))
  for i, it in ipairs(items) do
    local row = AcquireRow(box, i)
    local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(it.id)
    row.itemID = it.id
    row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    row.icon:SetDesaturated(it.removed)
    row.text:SetText((it.removed and "|cff808080" or "") .. (link or name or ("item:" .. it.id)) .. (it.removed and "  (removed)|r" or ""))
    -- right button
    if tier.key == "builtin" then
      row.btnB:SetText(it.removed and "Re-protect" or "Un-protect")
      row.btnB:SetScript("OnClick", function() if it.removed then GJ.ProtectRestoreBuiltin(it.id) else GJ.ProtectRemove(it.id, "builtin") end end)
      row.btnA:Hide()
    else
      row.btnB:SetText("Delete")
      row.btnB:SetScript("OnClick", function() GJ.ProtectRemove(it.id, tier.key) end)
      if tier.key == "character" then
        row.btnA:SetText("Promote"); row.btnA:SetScript("OnClick", function() GJ.ProtectPromote(it.id) end); row.btnA:Show()
      elseif db.UsePerCharacter then
        row.btnA:SetText("Demote"); row.btnA:SetScript("OnClick", function() GJ.ProtectDemote(it.id) end); row.btnA:Show()
      else
        row.btnA:Hide()
      end
    end
    row:Show()
  end
  for i = #items + 1, #box.rows do box.rows[i]:Hide() end
  box.listFrame:SetHeight(math.max(ROW_H, #items * ROW_H))
  if #items == 0 then
    box.empty:SetText(tier.key == "builtin" and "No built-in entries yet." or "Empty. Shift-right-click the display, or use the Add box below.")
    box.empty:Show()
  else box.empty:Hide() end
end

-- ---------------------------------------------------------------------------
-- public: build + refresh
-- ---------------------------------------------------------------------------
function GJ.ProtectUI_Refresh()
  if not root then return end
  db = GJ.db
  perCharCheck:SetChecked(db.UsePerCharacter and true or false)
  local y = -(perCharCheck:GetHeight() + 6)
  for _, tier in ipairs(TIERS) do
    local box = boxes[tier.key]
    if tier.perCharOnly and not db.UsePerCharacter then
      box:Hide()
    else
      box:ClearAllPoints(); box:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
      RenderBox(box); box:Show()
      y = y - box:GetHeight() - 6
    end
  end
  addBox:ClearAllPoints(); addBox:SetPoint("TOPLEFT", root, "TOPLEFT", 60, y - 4)
  addCharBtn:SetShown(db.UsePerCharacter and true or false)
  root:SetHeight(-y + 30)
  if GJ.OptionsLayoutChanged then GJ.OptionsLayoutChanged() end
end

function GJ.ProtectUI_Build(parent, width)
  db = GJ.db
  root = CreateFrame("Frame", nil, parent)
  root:SetSize(width, 100)

  perCharCheck = CreateFrame("CheckButton", nil, root, "InterfaceOptionsCheckButtonTemplate")
  perCharCheck:SetPoint("TOPLEFT", 0, 0)
  perCharCheck.Text:SetText("Use a per-character list as well (account list still applies to every character)")
  perCharCheck:SetScript("OnClick", function(self) db.UsePerCharacter = self:GetChecked() and true or false; GJ.Scan(); GJ.ProtectUI_Refresh() end)

  for _, tier in ipairs(TIERS) do boxes[tier.key] = CreateBox(root, tier, width) end

  -- Add row
  local addLabel = root:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  addLabel:SetText("Add item:")
  addBox = CreateFrame("EditBox", "GotJunkProtectAddBox", root, "InputBoxTemplate")
  addBox:SetSize(220, 20); addBox:SetAutoFocus(false)
  addLabel:SetPoint("RIGHT", addBox, "LEFT", -8, 0)
  -- Shift-clicking an item link while this box has focus inserts the link (Blizzard's ChatEdit hook).
  hooksecurefunc("ChatEdit_InsertLink", function(link) if addBox:HasFocus() and link then addBox:SetText(link); return true end end)
  local function ParseAdd()
    local txt = addBox:GetText() or ""
    local id = tonumber(txt) or tonumber(txt:match("item:(%d+)"))
    if not id then GJ.Print("Add: paste an item link or itemID"); return nil end
    return id
  end
  addAccountBtn = CreateFrame("Button", nil, root, "UIPanelButtonTemplate")
  addAccountBtn:SetSize(110, 20); addAccountBtn:SetPoint("LEFT", addBox, "RIGHT", 6, 0); addAccountBtn:SetText("Add to account")
  addAccountBtn:SetScript("OnClick", function() local id = ParseAdd(); if id then GJ.ProtectAdd(id, "account"); addBox:SetText("") end end)
  addCharBtn = CreateFrame("Button", nil, root, "UIPanelButtonTemplate")
  addCharBtn:SetSize(120, 20); addCharBtn:SetPoint("LEFT", addAccountBtn, "RIGHT", 4, 0); addCharBtn:SetText("Add to character")
  addCharBtn:SetScript("OnClick", function() local id = ParseAdd(); if id then GJ.ProtectAdd(id, "character"); addBox:SetText("") end end)
  addBox:SetScript("OnEnterPressed", function() addAccountBtn:Click() end)
  addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  -- Item names arrive async; re-render when they do.
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
  ev:SetScript("OnEvent", function() if root:IsVisible() then GJ.ProtectUI_Refresh() end end)

  GJ.ProtectUI_Refresh()
  return root
end
