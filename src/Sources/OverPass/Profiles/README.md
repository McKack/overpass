# Profiles

One INI file per app, named after it: `<id>.ini` (the id is the file name without the extension, for
example `gog-galaxy`). You can edit these files without building anything.

A file can hold two kinds of sections.

- Recipe sections `[app]`, `[install]` and `[launch]`. All three are optional. Only the OverPass app
  reads them. They describe how to install and start the app.
- Every other `[section]` is a compatibility rule. OverPass and overpass-wine both read rules.
  overpass-wine applies them to every process, including programs a launcher starts on its own.

A file with no `[app]` section is rules only (for example `armored-core-vi.ini`). It does not appear
in the app's store list.

Recipe sections use none of the rule keys, except `steam-app`, `env`, `dll` and `graphics` in `[app]`.
overpass-wine ignores recipe sections unless `[app]` has `steam-app`. Then the `env`, `dll` and
`graphics` of `[app]` apply to that Steam game.

Comments start with `#` or `;` at the beginning of a line. Keys are not case sensitive.

## [app]

| Key | Meaning | Repeatable |
|---|---|---|
| `name` | Display name. Defaults to the file id | no |
| `category` | Group the app is listed under | no |
| `featured` | Number. Puts the app on Home, in this order | no |
| `coming-soon` | `true` shows the app on Home as "Coming soon…" with Install disabled, and hides it from the Install sheet | no |
| `steam-app` | Steam app ID | no |
| `gog-game` | GOG product ID. With `steam-app`, makes the profile's runtimes apply to the game in whichever game client installed it | no |
| `brand-color` | Hex color without `#`, e.g. `86328A` | no |
| `rating` | `platinum`, `gold`, `silver`, `bronze`, `borked` or `untested` (default) | no |
| `tested-with` | What the rating was tested with | no |
| `rating-date` | Date of the rating | no |
| `rating-notes` | Notes on the rating | no |
| `bottle` | Windows version template for the container. `windows7`, `windows10` (default) or `windows11`. `container` works too | no |
| `bottle-group` | Apps with the same group share one container. `container-group` works too | no |
| `runtime` | Runtime to install into the container: `vcrun`, `corefonts`, `d3dcompiler_47`, `cjkfonts` or `directx_jun2010` | yes |
| `dependency` | Another profile this app needs | yes |
| `env` | `NAME=value`, set for the app | yes |
| `dll` | `name=mode` DLL override | yes |
| `graphics` | `dxmt`, `d3dmetal`, `wined3d`, `dxvk` or `auto` (default) | no |
| `controllers` | `playstation`: DualShock 4 and DualSense reach the container as PlayStation controllers (Sony's PC ports: haptics, adaptive triggers) instead of Xbox pads (default `xbox`). Applied when the container is made; changed later in the container's settings | no |
| `icon` | File name of an image in your Profiles/Icons folder (`~/Library/Application Support/OverPass/Profiles/Icons`), shown instead of the app's Windows icon. Set by the profile editor | no |
| `notes` | Free text shown with the app | no |
| `engine` | Game engine shown in the library's Engine column, e.g. `Unity` or `Unreal Engine`. Without it, OverPass tells the engine from the game's files, or shows Unknown | no |
| `source` | `title | url`: where the information comes from | yes |

## [install]

| Key | Meaning | Repeatable |
|---|---|---|
| `download` | URL of the installer | no |
| `github-release` | `owner/repo asset-pattern`: an asset of the latest GitHub release | no |
| `latest-link` | `url json.key.path`: URL of a JSON document, and the key that holds the download link | no |
| `download-page` | Web page where the user can get the installer | no |
| `file` | Installer file name pattern. `*` matches any run of characters. Used to recognize an installer you open | yes |
| `silent` | Silent-install switches, separated by spaces | yes |
| `wait-ignore` | Name of a process not to wait for after installing | no |

## [launch]

| Key | Meaning | Repeatable |
|---|---|---|
| `executable` | Windows path of the program to start. Required | no |
| `argument` | Arguments, separated by spaces | yes |
| `stale-file` | Windows path pattern. Matching files are removed before launch when nothing runs in the container | yes |
| `json-setting` | `<Windows path> \| <key> \| <value>`: sets a string value in the program's JSON settings file before launch, when nothing runs in the container and the file exists | yes |

## Compatibility rules

Per-program fixes. overpass-wine applies a rule whenever a matching program starts. OverPass applies
the same rules to the program it launches itself. Each `[section]` other than the three above is one
rule:

```ini
# Why the rule exists: what breaks without it.
[GOG Galaxy: software rendering]
program = GalaxyClient.exe
add-arguments = --in-process-gpu --use-gl=swiftshader
unless-argument = --type=crashpad-handler
source = https://...
```

| Key | Meaning | Repeatable |
|---|---|---|
| `program` | A program the rule covers: file name (`GalaxyClient.exe`) or path ending (`GOG Galaxy\GalaxyClient.exe`), any case | yes |
| `steam-app` | A Steam game, by app ID (matched through the `SteamGameId` Steam gives the game) | yes |
| `add-arguments` | Appended to the program's command line | yes |
| `unless-argument` | Don't append arguments to a command line containing this | no |
| `env` | `NAME=value`, set for the program | yes |
| `dll` | DLL override in `WINEDLLOVERRIDES` syntax, e.g. `xaudio2_7=n,b` | yes |
| `graphics` | `dxmt`, `d3dmetal`, `wined3d`, `dxvk` or `auto` | no |
| `d3d9` | `mtld3d` or `wined3d`: Direct3D 9 for the program, after any `graphics` line | no |
| `replace-path` | `from => to`: start another program instead. The part of the program's path matching `from` (any case) is replaced by `to`, or the whole path when `to` is absolute (`C:\...`). The arguments stay. Skipped when the new program doesn't exist | yes |
| `source` | Where the fix comes from: bug report, test, forum thread | yes |

A rule applies when any of its `program` or `steam-app` lines match. Matching rules apply in file-name
order, then in order within a file.

Before adding a rule, test it: run the program with and without it, and put what you saw in the
comment and `source`.

## Your own profiles

Profiles you edit or make in OverPass live in `~/Library/Application Support/OverPass/Profiles`. They use
the same format as the bundled ones. A file there named like a bundled profile replaces it.

The first line of a copy of a bundled profile records which version it was copied from, so OverPass can
say when the original has changed:

```ini
# Based on OverPass's profile version <hash>
```

Revert to Original deletes the copy.

A profile made for an app without one has an `[app]` section with `name`, `rating` and `bottle`. Store
games also get `steam-app` or `gog-game`. Other apps get a `[launch]` `executable`, which is how OverPass
finds the app again.

The editor writes the app's own settings to a rule section named `[My settings]`: `program` or
`steam-app` lines for the app, then `add-arguments`, `graphics`, `env` and `dll`. Choosing Microsoft's
XAudio2 adds `dll = xaudio2_6=n,b`, `xaudio2_7=n,b`, `x3daudio1_6=n,b` and `x3daudio1_7=n,b`.

OverPass copies the profiles in effect (bundled ones that yours do not replace, plus yours) to
`~/Library/Application Support/OverPass/Rules`. overpass-wine reads rules from that folder.

Export writes the profile without the "Based on" line. File > Import Profile… adds one. A file with the
same name replaces the existing profile.

## Example

```ini
[app]
name = GOG Galaxy
category = Game Launcher
featured = 3
brand-color = 86328A
rating = untested
container-group = gog
runtime = vcrun
dll = GalaxyOverlay.exe=d
source = Winget manifest | https://github.com/microsoft/winget-pkgs/tree/master/manifests/g/GOG/Galaxy

[install]
latest-link = https://remote-config.gog.com/components/webinstaller?component_version=2.0.0 content.windows.downloadLink
file = setup_galaxy_*.exe
silent = /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-
wait-ignore = GalaxyClient.exe

[launch]
executable = C:\Program Files\GOG Galaxy\GalaxyClient.exe
stale-file = C:\ProgramData\GOG.com\Galaxy\lock-files\*.lock

# Galaxy's Chromium GPU process fails under Wine on macOS. Render in software in the main process.
[GOG Galaxy: software rendering]
program = GalaxyClient.exe
program = GalaxyClient Helper.exe
add-arguments = --in-process-gpu --use-gl=swiftshader
unless-argument = --type=crashpad-handler
```
