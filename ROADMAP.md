# OverPass roadmap

Where OverPass is going, in plain terms. Two things come first: more games working, and less for you to set up.
Looks and extras follow, and it all ends with 1.0.0.

The order can change as we test real games. Want to help it along? [Support OverPass on Ko-fi](https://ko-fi.com/arctim),
[report an issue](https://github.com/McKack/overpass/issues), or send in a profile from the profile editor.

| Version | Theme | In short |
|---|---|---|
| 0.6.7 | Tidy-up | Submit your own profiles, small fixes |
| 0.7 | Just Works | 32-bit and 64-bit games set themselves up |
| 0.8 | Graphics | VSync, Max FPS, a big pass of game fixes |
| 0.9 | Game Screen | Fullscreen and window modes that always behave |
| 0.10 | Sound, video and controllers | Fewer audio problems, full DualSense support |
| 0.11 | DLSS, upscaling and Vulkan | More ways to get more frames |
| 0.12 | Stores and game services | Updates, cloud saves, Steam built in |
| 0.13 | Community and comforts | Ratings, performance overlay, Downloads page |
| **1.0.0** | **Big Picture and the new look** | **Play from the couch with a controller** |

## 0.6.7: Tidy-up

| Type | What |
|---|---|
| Feature | Rate a game and send its settings in, with an optional comment |
| Fix | "Epic Games" spelled out on covers and labels |
| Fix | Containers from offline installers are named after the game |
| Fix | Games started from their Mac app open in front |

## 0.7: Just Works

You shouldn't need to know how a game was built to play it.

| Type | What |
|---|---|
| Feature | 32-bit and 64-bit games pick the right graphics and CPU settings on their own |
| Feature | OverPass recognises a game's engine and applies known settings for it |
| Feature | Missing components are offered when a game needs them |
| Feature | New game profiles arrive without an app update |
| Feature | Hundreds more games get known settings, from the open Highball database |
| Feature | Clearer profile editor: Direct3D, Display, Sound, Input each in their own place |
| Feature | Games with several launch options show them in one library entry |

## 0.8: Graphics

| Type | What |
|---|---|
| Feature | VSync and Max FPS settings for each game |
| Feature | Reusable game fixes that work across similar games |
| Fix | Less shader stutter in Direct3D 12 games |
| Support | Unreal Engine 5 Nanite groundwork |
| Support | HDR and smoother frame pacing |
| Testing | A big real-game pass, with each game rated |

## 0.9: Game Screen

Every game renders to a virtual screen, and OverPass turns its window-mode requests into what you see on your Mac.
Fullscreen, borderless and windowed then work the same way in every game, whichever engine it uses. This is the big
one for this stretch of the roadmap.

| Type | What |
|---|---|
| Feature | Game Screen for Direct3D 10–12 games |
| Feature | Game Screen for Direct3D 9 and older games |
| Feature | Resize a game's window freely, and the picture follows |
| Fix | No more menu bar over a game, or a picture in the wrong size |

## 0.10: Sound, video and controllers

| Type | What |
|---|---|
| Fix | Less crackling in more games, Bluetooth headphones included |
| Support | Game cutscene and video formats, checked per game |
| Support | DualSense haptics and adaptive triggers, wired and Bluetooth |
| Feature | Controller presets for each game |
| Feature | Better raw mouse input |

## 0.11: DLSS, upscaling and Vulkan

| Type | What |
|---|---|
| Support | DLSS in more games, with Ray Reconstruction and Frame Generation |
| Support | FSR4 as an option |
| Feature | MetalFX upscaling for any game |
| Support | DXVK for Direct3D 9 |
| Support | Vulkan fallback for Direct3D 12 |
| Support | Newer OpenGL games |

## 0.12: Stores and game services

| Type | What |
|---|---|
| Testing | EA, Battle.net, Ubisoft, Rockstar and other launchers |
| Feature | Game updates and repair for Epic Games and GOG |
| Feature | Cloud saves for Epic Games and GOG |
| Feature | Steam library built in to OverPass |
| Feature | Steam notifications as Mac notifications |
| Feature | Xbox library (opt-in) |

## 0.13: Community and comforts

| Type | What |
|---|---|
| Feature | "How did it run?" community ratings, with expected FPS per Mac |
| Feature | Performance overlay with its own hotkey |
| Feature | Automatic crash reports, if you want them |
| Feature | One Downloads page for everything |
| Feature | Drag games onto categories |

## 0.14: Standing alone

OverPass keeps working after Apple winds Rosetta down, and no longer needs Apple's D3DMetal.

| Type | What |
|---|---|
| Support | Runs on Apple silicon without Rosetta, ready for macOS 28 |
| Support | 32-bit games keep working without Rosetta |
| Support | overpass-runtime covers what games use D3DMetal for, including ray tracing |

## 1.0.0: Big Picture and the new look

The whole refreshed interface arrives at once, to celebrate.

| Type | What |
|---|---|
| Feature | Big Picture mode for your TV |
| Feature | Navigate OverPass with a controller |
| Feature | New Home: a big hero banner with rows like Continue Playing and New to Your Library |
| Feature | New game pages with playtime, size and news |
| Feature | Dark and light look for Windows programs |

## After 1.0

Ideas we want to explore, without promises yet.

| Type | What |
|---|---|
| Feature | Steam games without the Windows Steam client |
| Feature | Native ports: use tools that turn games you own into Mac apps |
| Feature | Emulators, with their games in your library |
| Feature | Widescreen and frame-rate patches in game profiles |
