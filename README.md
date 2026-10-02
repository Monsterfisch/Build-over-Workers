# Build Over Workers

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme. You can place buildings
and walls where your own (and, optionally, your allies') workers are standing; soldiers and
enemy units still block. Anyone standing where a new building or wall goes up - yours or the
AI's - is moved to the nearest free tile next to it and walks on, instead of being removed or
left stuck inside.

What the module does, in plain English, is in `module/locale/description-en.md`.

## What is in here

| Folder | |
|---|---|
| `module/` | the module itself - this is the source of truth, edited in place |
| `bench/` | the emulator bench: the module's own Lua runs against the real exe image, its assembly is assembled with UCP's own fasm.dll and then executed |
| `tools/publish.py` | copies `module/` into the game's module folder under a new version |

## Working on it

1. Edit under `module/`.
2. Run the bench until it is green: `bench/test_bow.py` (the placement tests for buildings and
   walls, remembering built-over tiles, AI walls, and moving the units afterwards), on both
   executables.
3. `python tools/publish.py --bump` - raises the last version slot and copies the module to
   `ucp/modules/build-over-workers-<version>`, leaving the build before it installed and
   clearing anything older.
4. In the UCP GUI press F5, then apply. `ucp-config.yml` is never edited by hand: the apply
   button moves the pin.
5. Commit and tag: `git commit -am "<version> - <what changed>" && git tag v<version>`.

The bench needs Python with `lupa`, `capstone`, `pefile` and `keystone-engine`, and a 32-bit
PowerShell for fasm.dll; it reads the executables from the game folder named in `shc.py`.
