-- Built-in protected items: grey/white items a fresh character actually wants to keep.
-- Ships with the addon; the user can remove entries (GotJunkDB.BuiltinRemoved) and they
-- stay removed across updates. Seeded from the owner's in-game 'Copy list' hand-off.
--
-- Format:  [itemID] = true,  -- Item Name
local _, GJ = ...

GJ.BuiltinProtect = {
  -- tools / long-lived utility items a levelling character wants to keep
  [1191] = true,  -- Bag of Marbles
  [1434] = true,  -- Glowing Wax Stick
  [6256] = true,  -- Fishing Pole
  [6529] = true,  -- Shiny Bauble
  [7005] = true,  -- Skinning Knife
}
