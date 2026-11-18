# Changelog

## Unreleased

- Initial version: worst-junk display (LDB + standalone panel), click to destroy,
  auto-drop on loot click with keep-clear / below-10c / below-2% thresholds, protect list.- Display gate: junk is only shown when fewer than N slots are free (default 3).
- Panel previews for 30s at login and for 30s after hovering it, even below the show threshold.
- Bag occupancy strip: one dot per general-bag slot (bright = used, grey = free) above the junk row.
- Food & water policy: never / keep N stacks per item (default 3) / low-level only.
- 'Auto-hide panel when no eligible junk' checkbox (default on).
- Options page reorganised into bordered sections (Display / Auto-drop / Food and water); auto-hide now first and off by default.
- Panel: desaturated bag icon when nothing to drop; icon+text row centred under the dots.
- Protected lists v2: three tiers (character / account / built-in), union semantics. Per-character tier hidden until enabled. Options page lists each tier with Delete / Promote / Demote / Restore, a 'Copy list' hand-off frame (itemID<TAB>name), and an Add box. /gotjunk protect [account|character] <link>.
- Food & water reworked: radio is never / low-level only; checkboxes for excess non-buff stacks (keep N), low-level buff food (on), off-class buff food (off). Buff food detected by tooltip scan; existing 'stacks' setting migrates to lowlevel + excess.
- Auto-drop now sizes itself to the loot: counts slots the open loot window needs (merges into partial stacks count as 0) and drops enough junk to cover keep-clear + incoming, worst-first, all passing thresholds.
- Auto-drop worth-guard: on a loot click, a bag slot is only destroyed if its full-stack value is below the cheapest junk-ish item in the loot; otherwise nothing is freed and the pickup is left to fail, with a chat line saying why.
