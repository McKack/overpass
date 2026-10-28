# Credits

Almost everything that makes Windows games run on a Mac was built by the people and projects below, over many
years. OverPass wouldn't exist without any of them, so consider donating to them first.

If you'd like to support OverPass itself too, there's [Ko-fi](https://ko-fi.com/arctim). Thank you!

## Wine and CodeWeavers

- **[Wine](https://www.winehq.org)** runs Windows programs on macOS, Linux and BSD, and is the core of
  overpass-wine. LGPL-2.1. [Donate to Wine](https://www.winehq.org/donate).
- **[macOS Wine builds by Gcenx](https://github.com/Gcenx/macOS_Wine_builds)** are the upstream Wine builds
  OverPass falls back to, and a reference for building Wine on macOS. LGPL-2.1.
- **[CodeWeavers](https://www.codeweavers.com)**: overpass-wine is built from Wine and from the LGPL Wine
  source CodeWeavers publishes for CrossOver. Give their [Trial](https://www.codeweavers.com/crossover) a try
  and see if CrossOver could be for you!
- **[Alexander Theißen's Wine fixes](https://github.com/athei/wine/tree/cx-26-patched)** (Mach9): Mac driver,
  DEP and font fixes on the same CrossOver 26 base, included in overpass-wine with their authorship. LGPL-2.1.

## Graphics

- **[DXMT](https://github.com/3Shain/dxmt)** by Feifan He (for CodeWeavers) translates Direct3D 10, 11 and 12
  to Metal. overpass-runtime is DXMT with our patches. LGPL-2.1.
- **[mtld3d](https://github.com/athei/mtld3d)** by Alexander Theißen runs Direct3D 9 on Metal. overpass-runtime
  carries its releases unchanged. zlib licence.
- **[DXVK](https://github.com/doitsujin/dxvk)** by Philip Rebohle and contributors translates Direct3D 8-11
  to Vulkan; DXMT builds on parts of it too. zlib licence.
- **[MoltenVK](https://github.com/KhronosGroup/MoltenVK)** runs Vulkan on Metal, with the
  **[Vulkan loader](https://github.com/KhronosGroup/Vulkan-Loader)**. Apache-2.0.
- **[LLVM](https://llvm.org)** powers DXMT's shader compiler. Apache-2.0 with LLVM exception.
- **[Apple's Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)** provides
  D3DMetal, an optional graphics engine OverPass can download. Apple's licence; not part of OverPass.

## Inside overpass-wine

- **[GStreamer](https://gstreamer.freedesktop.org)** and **[GLib](https://gitlab.gnome.org/GNOME/glib)**
  play game video and audio. LGPL-2.1.
- **[FFmpeg](https://ffmpeg.org)** decodes Windows Media formats (an LGPL build).
  [Donate to FFmpeg](https://ffmpeg.org/donations.html).
- **[libvpx](https://chromium.googlesource.com/webm/libvpx)** (VP8, VP9), and Xiph's
  **[Ogg, Vorbis and Opus](https://xiph.org)**. BSD licences. [Donate to Xiph](https://xiph.org/donate/).
- **[FreeType](https://freetype.org)** renders fonts. FreeType Licence.
- **[GnuTLS](https://www.gnutls.org)**, **[Nettle](https://www.lysator.liu.se/~nisse/nettle/)** and
  **[GMP](https://gmplib.org)** handle secure connections. LGPL.
- **[SDL](https://www.libsdl.org)** handles game controllers. zlib licence.
- **[libinotify-kqueue](https://github.com/libinotify-kqueue/libinotify-kqueue)** lets programs watch folders
  for changes. MIT.
- ORC, PCRE2, libffi and proxy-libintl, used by GStreamer and GLib. BSD, MIT and LGPL.

Each build of overpass-wine carries these projects' licence texts in its `licenses` folder.

## Tools

- **[winetricks](https://github.com/Winetricks/winetricks)** installs Windows components into bottles.
  LGPL-2.1. [Sponsor its maintainer](https://github.com/sponsors/austin987).
- **[Legendary](https://github.com/legendary-gl/legendary)** by Rodney (derrod) and contributors is the Epic
  Games Store client behind the Epic Games Library. GPL-3.0; OverPass downloads upstream's own macOS build and
  runs it as a separate program. [Heroic Games Launcher](https://heroicgameslauncher.com) and Highball showed
  how to drive it.
- **[gogdl](https://github.com/Heroic-Games-Launcher/heroic-gogdl)** by imLinguin and the Heroic Games Launcher
  contributors downloads games for the GOG Library. GPL-3.0; OverPass downloads upstream's own macOS build and runs
  it as a separate program. Heroic Games Launcher showed how to drive it and set games up after the download.

## Kindred projects

- **[Highball](https://gethighball.com)** shares OverPass's goals. Its
  [credits page](https://gethighball.com/docs/credits/) inspired this one. Its
  [open compatibility database](https://github.com/gauthierpiarrette/highball-db) found which anti-cheats never
  run on macOS; OverPass marks those red.
- **[Are We Anti-Cheat Yet?](https://areweanticheatyet.com)** collects which games use which anti-cheat (MIT).
  OverPass downloads its list to warn before a game with an anti-cheat starts.
- **[ProtonDB](https://www.protondb.com)** collects community compatibility reports, the model for OverPass's
  open profile database.
- **[Lutris](https://lutris.net)**, **[Bottles](https://usebottles.com)** and
  **[Whisky](https://github.com/Whisky-App/Whisky)** are open-source Wine front-ends whose install scripts and
  ideas inform OverPass. GPL.

## Trademarks

Steam is a trademark of Valve Corporation. Epic Games and the Epic Games Store are trademarks of Epic Games,
Inc. GOG.com and GOG Galaxy are trademarks of GOG sp. z o.o. EA and the EA app are trademarks of Electronic
Arts Inc. Battle.net is a trademark of Blizzard Entertainment, Inc. Rockstar Games is a trademark of Take-Two
Interactive Software, Inc. Ubisoft and Ubisoft Connect are trademarks of Ubisoft Entertainment. Xbox is a
trademark of Microsoft Corporation.

Store logos only identify each store. They come unmodified from [Simple Icons](https://simpleicons.org) (CC0)
and, for Xbox, [Bootstrap Icons](https://icons.getbootstrap.com) (MIT); the GOG Galaxy mark in the app is
OverPass's own. OverPass is not affiliated with or endorsed by any of these companies.
