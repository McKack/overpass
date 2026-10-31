# Changelog

What changed in each release of OverPass, newest first. The short list at the top of each version is what OverPass shows after an update.

## 0.6.7 - Unreleased

- Rate a game and send in its settings, with a comment if you like
- Games started from their Mac app open in front
- Containers made from offline installers are named after the game
- What's New: this list, after every update
- Smaller bug fixes and improvements

### Details

**Profiles**
- Submit Rating & Profile in the profile editor: rate a title once it has been started, add a comment if you like, and send its settings in for review. With a matching OverPass Runtime the submission includes the game's frame rates.

**Games**
- Games started from their Mac app come to the front instead of opening behind Finder.
- Containers made from offline installers are named after the game.
- Starting no longer shows on every Steam game, only the one being started.
- The report hotkey no longer asks for Screen Recording: the system prompt came up over the game.

**Setup**
- The setup wizard offers OverPass Runtime, the recommended way to run game graphics.

**Library**
- Help › What's New shows the latest updates, and OverPass opens it once after each update.
- The right-click menu keeps Add to Favorites and Add to Category together, with Hide after them.
- "Epic" is spelled out as "Epic Games" on labels.

## 0.6.6 - 2026-10-31

- Less crackling in DirectSound games, on Bluetooth headsets especially
- No more trips to Audio MIDI Setup: sound settings are matched for you
- Smaller bug fixes and improvements

### Details

**Sound**
- OverPass Wine 11.0-12 sizes sound buffers to your Mac's sound output, which should stop crackling in DirectSound games on outputs such as Bluetooth headsets. Update it in Settings › Components.
- The Sound tab no longer sends you to Audio MIDI Setup: sample rates and buffers are matched automatically.

**Reports**
- Reports now list sound outputs and how they're connected, displays, and the kinds of Bluetooth devices connected. Bluetooth device names are left out.

## 0.6.5 - 2026-10-30

- 32-bit Direct3D 10 and 11 games run on Metal instead of the slower fallback
- Report a problem or suggest a feature from the Help menu, no GitHub account needed
- Smaller bug fixes and improvements

### Details

**32-bit games**
- OverPass Runtime 0.4.0 runs 32-bit Direct3D 10 and 11 games on Metal; until now they silently fell back to the slower WineD3D. Update it in Settings › Components. In A Short Hike this also fixes the game vanishing when switched to full screen.

**Reports**
- Help › Report Issue… reports a problem with OverPass itself, and Help › Request Feature… sends an idea. Neither needs a GitHub account.
- ⌃⌘R reports from inside a running game, and the report windows now say so. A game started from the Dock or Applications folder starts OverPass in the background, so the key works then too. For a program that isn't in your library, it opens a report on OverPass.

**Updates**
- An update that can't replace the app says so and leaves the old copy working. A copy macOS runs from a temporary location updates into Applications.

## 0.6.4 - 2026-10-29

- Choose how often OverPass checks for updates
- OverPass opens on the page you left it on
- Smaller bug fixes and improvements

### Details

**Fixes**
- Hidden titles shown with View › Show Hidden Items have their menu again, so they can be unhidden.

**Updates**
- Settings › Components › Automatic Updates: check for updates Never, once an hour, every 6, 12 or 24 hours, once a week or once a month, and, with the switch, also when OverPass starts and when you come back to it once that long has passed. The setup wizard asks whether to check automatically. The two update switches in Settings › General are replaced by this.

**Library**
- OverPass opens on the page or category you had open when you closed it.
- View › Categories › Show Category Clients is gone: a game client's category always lists the client with its games.

## 0.6.3 - 2026-10-29

- Hide anything you don't want to see in your library
- Smaller bug fixes and improvements

### Details

**Library**
- Hide anything you don't want to see: right-click a title, or a game in the Epic Games or GOG library, and choose Hide. View › Show Hidden Items (⇧⌘.) shows them again, dimmed, with Unhide in their menu. Handy for the extra shortcuts some installers add, such as a map editor or a language setup.
- The Epic Games library leaves out Epic's own Unreal Engine tools, such as Live Link Hub.

**Profiles**
- Profile notes and sources are written in general terms, and say container instead of bottle.

## 0.6.2 - 2026-10-29

- Smaller bug fixes and improvements

### Details

**Fixes**
- Removing a setting or DLL override in a game's Advanced tab while typing in it no longer makes OverPass quit (#1).
- OverPass's own crash reports are no longer turned away for lacking a game's details.

## 0.6.1 - 2026-10-29

- Known settings for about 140 more games, not yet tested on OverPass
- Smaller bug fixes and improvements

### Details

**Presets**
- Settings that many games need now come as presets, one per setting, with the games that need it. OverPass ships presets for about 140 games, covering graphics, sound and common Windows components. These games haven't been tested on OverPass yet: reports welcome.
- Any game can use a preset from its profile, and profiles can carry their own.
- A graphics choice you make yourself always wins over a preset.

**Fixes**
- The app menu shows Settings… once again.

## 0.6.0 - 2026-10-29

- Home shows your game stores and services
- Epic Games and GOG install straight to OverPass's built-in library
- Fewer blank windows in launchers and in-game browsers
- The Command key no longer gets stuck after Command-Tab
- Smaller bug fixes and improvements

### Details

Get the matching OverPass Wine 11.0-10 from Settings › Components › Update All.

**Home**
- Home shows the gaming services: Steam, Epic Games, GOG, EA, Battle.net, Rockstar, Ubisoft and Xbox. The other apps OverPass has profiles for (utilities, music players) come back with Settings › Advanced › **Other recommended apps**.
- Install on Epic Games and GOG goes straight to OverPass's built-in library. To get the stores' own Windows apps (Epic Games Launcher, GOG Galaxy) offered too, turn on Settings › Advanced › **Legacy game clients**. Clients you already installed keep working.

**Compatibility**
- Fewer blank windows in launchers and in-game browsers built on Chromium. Profiles can recognise such programs with the new `beside` key.

**With OverPass Wine 11.0-10**
- Command no longer stays held after Command-Tab, Command-Space or Command-Q, which turned typing into shortcuts and beeps.
- Fixes to how Windows programs read, open and resize files, for a few big games.

## 0.5.0 - 2026-10-29

The first public release of OverPass, open source under the GPL-3.0 and made by [Arctic Imaginarium](https://arctim.no).

- The first public release
- Epic Games sign-in works
- Installed Only shows just the games you have installed
- See each game's engine in the list view
- Smaller bug fixes and improvements

### Details

Get the matching OverPass Wine 11.0-9 from Settings › Components › Update All.

**Stores**
- Epic Games sign-in works: OverPass opens Epic's login page and finishes on its own once you're in. Signing in loads your whole library, which can take a couple of minutes; OverPass now says so.
- Fab and Unreal Engine marketplace items, and engine editors and dev kits, are left out of the Epic library.
- GOG and Epic Games: installed games get a Play button where the others say Install, and the new **Installed Only** button hides the games you haven't installed.
- Store games say Play; other programs say Run.

**Library**
- Covers show the store's icon in front of each name (not inside the store's own category, where you know where you are). Cover with Label is gone from View › Cover View.
- Game cases have a flat band in the store's colour. Steam is its dark blue instead of black, Mac apps are blue with the Apple logo, other programs peach.
- The list view shows Container, a new **Engine** column (Unity, Unreal Engine, Godot and more, found from the game's files or set with `engine` in a profile) and Graphics.
- Rows no longer repeat a name ("GOG · GOG").
- The toolbar keeps everything in the middle: the selection's actions with Install and Quick Run, then layout, sort and Installed Only. The store account sits beside the search field.

**With OverPass Wine 11.0-9**
- Dock and menu bar names drop ".exe" and start with a capital letter, and Steam shows as "Steam" instead of "steamwebhelper.exe".
