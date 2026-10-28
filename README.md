# moonsweepers-change-host

Lets someone else host your MoonSweepers world without everyone ending up with the wrong inventory.

MoonSweepers saves the host's player data (inventory, upgrades, garage, …) under the name `local`, and everyone else under their Steam ID. When you send your save to a friend and they host it, they get *your* inventory. `swap-host.ps1` moves the data around so the new host gets their own stuff, and the old host's stuff is waiting for them under their Steam ID.

## Old host: send the save

1. Close the game.
2. Open `%USERPROFILE%\AppData\LocalLow\DragDropGames\MoonSweepers\MoonSessions` (paste it into the Explorer address bar).
3. Zip the slot folder of the world (e.g. `slot-1`) and send it to the new host.
4. Tell the new host your Steam profile link or SteamID64 (they can also copy it from your Steam profile).

## New host: switch it over

1. Close the game.
2. Put `swap-host.ps1` into `%USERPROFILE%\AppData\LocalLow\DragDropGames\MoonSweepers` (the folder that contains `MoonSessions`).
3. Unzip the slot folder into `MoonSessions`. If you already have a slot with that name, rename one of them (e.g. to `slot-2`) or back yours up first.
4. Open PowerShell in that folder and run:

   ```
   powershell -ExecutionPolicy Bypass -File swap-host.ps1
   ```

5. Pick the slot, pick yourself from the player list, then paste the old host's profile link or Steam ID when asked.
6. Check the summary and confirm with `y`. Start the game and host the world.

You must have joined this world at least once before. If you're not in the player list, there's no data of yours to swap in.

## Good to know

- Players can be entered as a list number, a SteamID64 (`7656119…`), or a profile link (`steamcommunity.com/profiles/…` or `steamcommunity.com/id/…`).
- The script remembers who the host is per slot in `swap-host-known.json`, so when you swap again later, you can just press Enter for the current host.
- Each run backs up the whole slot to `MoonSweepers\<slot>-backup-<date>-<time>` before writing. To undo, close the game and copy the backup back over the slot folder.
- Add `-DryRun` to see what would change without writing anything.
- Non-interactive: `powershell -ExecutionPolicy Bypass -File swap-host.ps1 <new host> <old host> [-Slot slot-2] [-DryRun]`
- Steam names are looked up on steamcommunity.com. Use `-Offline` to skip that (Steam IDs then have to be pasted as numbers).
- Only edit saves while the game is closed, otherwise the game or Steam Cloud may overwrite your changes.
