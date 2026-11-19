# Changelog

## Unreleased

First release. Classic Era and WoW Forever.

### Display
- Ever-present one-liner showing the least valuable grey/white slot: `[icon] x10 - 10c Name`.
- LibDataBroker data source `GotJunk` plus a standalone draggable panel (shown by default only when no LDB display host is detected). LibDBIcon minimap button.
- Bag occupancy strip above the row: one dot per general-bag slot, bright = used, grey = free, centred.
- Junk is only surfaced when fewer than N slots are free (default 3). Hovering the panel lifts the gate so the row shows exactly what a click would destroy.
- Panel previews for 30s at login so it can be found and moved. Optional auto-hide when nothing is eligible (default off).
- Visual style: classic rounded border or modern flat. Money shown gold / silver / copper coloured.
- Tooltip lists the five worst slots with current and full-stack value, total junk value, free slots and auto-drop status; rebuilt in place after every protect or drop.
- "Panel" options section: panel position and lock are stored account wide (default) or per character, chosen by a radio; `/gotjunk lock` and `/gotjunk reset` follow the chosen scope.

### Ranking
- Slots are ranked by full-stack value (`vendor price x max stack`) ascending, tie-broken by actual value, so a non-stacking 5c pelt goes before 3 x 1c water, and a 2/20 stack before a 20/20 stack of the same item.

### Actions
- Left-click destroys the shown slot. Right-click opens options. Shift-right-click protects the shown item.
- Auto-drop on loot click: when thresholds are met the click also destroys junk. The drop is sized to the loot - slots the open loot window needs (merges into existing partial stacks cost 0) plus the keep-clear reserve - worst-first, all passing the ticked thresholds (below 10c full-stack and/or below 2% of all junk; AND when both).
- Worth-guard: a bag slot is only destroyed if its full-stack value is below the cheapest junk-ish item in the loot; otherwise nothing is freed and the pickup is left to fail, with a chat line saying why.

### Food and water
- Never junk, or junk only low-level food/water (required level 10+ below yours, matching vendor tier spacing).
- Checkboxes: junk excess non-buff stacks beyond N per item (off); low-level Well Fed food eligible (on); off-class Well Fed food eligible (off). Buff food detected by a one-time tooltip scan.

### Protected items
- Three tiers, union semantics: per-character (hidden until enabled), account, built-in. Options page lists each with Delete / Promote / Demote / Un-protect / Re-protect, a Copy-list hand-off frame (`itemID<TAB>name`), and an Add box that accepts shift-clicked links or IDs.
- Built-in seed: Bag of Marbles, Glowing Wax Stick, Fishing Pole, Shiny Bauble, Skinning Knife. Removals persist across updates.
- `/gotjunk protect [account|character] <link|id>`, `/gotjunk protect list`.

### Slash
- `/gotjunk` - toggle panel | options | lock | reset | drop | scan | protect | status | tipdebug
- Minimap button hidden by default (toggle in options).
