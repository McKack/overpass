# When a Windows program has problems

OverPass runs Windows programs with overpass-wine. Most work out of the box; when one crashes, won't start or
looks wrong, these steps usually help. Each program's settings are in its profile: right-click it in the
library and choose **Edit Profile…**.

## It crashed ("Program Error")

1. Start it again. Launchers in particular sometimes crash once while they update themselves.
2. Make sure your Mac has free disk space. Programs that can't write their files crash in odd ways.
3. Try another graphics engine: **Edit Profile… → Direct3D**.
   - **overpass-runtime (Metal)** for DirectX 10, 11 and 12 games (install it in OverPass if you haven't yet).
   - **D3DMetal (Metal)** as an alternative for DirectX 11 and 12.
   - **DXVK (Vulkan via MoltenVK)** or **WineD3D (OpenGL)** for older or unusual games.
4. Quit everything in the container and try once more: **Edit Profile… → Container → Quit Everything in Container**.

## It doesn't start, or shows only a black window

- Check that its launcher (Steam, GOG Galaxy, Epic) is installed in the same container and signed in.
- Some games need extra Windows components. **Edit Profile… → Container** installs DirectX June 2010 (which
  includes Microsoft's XAudio2) and runs winetricks verbs.
- Windowed mode often helps a game that fails in fullscreen: add its own option (such as `-windowed`) under
  **Edit Profile… → General**.

## No sound, or crackling sound

- **Edit Profile… → Sound → XAudio2**: try Microsoft's XAudio2 instead of Wine's.
- Check the output device and sample rate in **Audio MIDI Setup** (the button is in the same section).

## Reporting a problem

If none of this helps and the program works on Windows:

1. Right-click the program and choose **How Did It Run?…**. Pick a medal, say what happened and turn on **Send
   logs**. **The last run** sends the log of its last run (errors and loaded DLLs, no new run); **Run with extra
   debugging** starts it with Wine's log on: do what causes the problem, then quit it, and the window comes back.
2. Press **Send**. OverPass files a public issue with the log and your Mac, macOS, OverPass, Wine and graphics details,
   without your name in them, and opens it. No GitHub account is needed.
