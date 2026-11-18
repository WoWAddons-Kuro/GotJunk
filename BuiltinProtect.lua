-- Built-in protected items: grey/white items a fresh character actually wants to keep.
-- Ships with the addon; the user can remove entries (GotJunkDB.BuiltinRemoved) and they
-- stay removed across updates. Seeded from the owner's in-game 'Copy list' hand-off.
--
-- Format:  [itemID] = true,  -- Item Name
local _, GJ = ...

GJ.BuiltinProtect = {
  -- (empty seed; populate from the Protected items > Built-in > Copy list hand-off)
}
