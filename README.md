# Level Zones

A free World of Warcraft Forever addon that suggests leveling zones and shows which dungeon quests you can still pick up.

The main panel shows the best zone now and where to go afterward. Open **Details** to see why, view the zone on the world map, or skip it until you level up. Dungeon rows show a level range and quest status. **Show lower** reveals older dungeons.

## Install

Download the extract-only ZIP under **Releases**.

1. Close WoW and extract the **LevelZones** folder into `World of Warcraft\_forever_\Interface\AddOns`. You should have `AddOns\LevelZones\LevelZones.toc`.
2. On your first login, enable **QuestieDB** and **DungeonJournal** for WoW Forever. Level Zones was built for the source interfaces in [QuestieDB 1.0.15](https://www.curseforge.com/wow/addons/questiedb/files/9563386) and [DungeonJournal 2.0.3](https://www.curseforge.com/wow/addons/dungeonjournal/files/9567829). You only need the database addon from Questie, so you can leave the Questie tracker off.
3. Log in. Level Zones builds the catalog and opens the panel automatically. Log out normally to save it. You can then disable both source addons. On future logins Level Zones opens using its saved catalog.

Click the map icon by the minimap to hide or reopen Level Zones. Right-click it to set the panel size, or drag it around the minimap to move the icon. The panel remembers its visibility and size per character. Use **Hide all** on the Dungeons heading to collapse the whole section. The zone suggestion box has its own **Details** button.

Drag the bar at the bottom of the panel to change its height. The top and sides stay put. The size slider still scales text and controls. Choose **Auto fit** in the size window to restore automatic height.

The catalog is stored account-wide in WoW's saved variables. The panel position, skipped dungeons and zone preference are stored per character. To refresh the catalog after a source update, enable both source addons and type **`/lvlzones rebuild`**.

The ZIP contains addon source and setup instructions. WoW does the setup through its addon API. Quest recommendations are estimates and may miss server-side requirements or quest changes.
