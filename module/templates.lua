-- FASM sources. Upper-case names are filled in by init.lua.
local templates = {}

-- Can every unit on a tile be built over by a player?
-- in: eax = first unit on the tile, ecx = the player placing
-- out: eax = 1 if all of them are friendly workers (or chickens), 0 if not
-- keeps ebx, esi, edi, ebp; changes ecx, edx
templates.tileCheck = [[
  push ebx
  push esi
  push edi
  mov esi, ecx
  mov edi, 64
next_unit:
  movzx eax, ax
  test eax, eax
  jz all_friendly
  dec edi
  jz not_friendly
  imul ebx, eax, 0x490
  movzx edx, word [ebx + UNIT_TYPE]
  cmp edx, CHICKEN
  je passed
  cmp edx, TYPE_COUNT
  jae not_friendly
  cmp byte [edx + WORKERS], 0
  je not_friendly
  movsx edx, word [ebx + UNIT_OWNER]
  cmp edx, esi
  je passed
  cmp byte [ALLIES], 0
  je not_friendly
  cmp edx, 1
  jl not_friendly
  cmp edx, PLAYERS
  jg not_friendly
  cmp esi, 1
  jl not_friendly
  cmp esi, PLAYERS
  jg not_friendly
  mov ecx, [edx*4 + TEAMS]
  test ecx, ecx
  jz not_friendly
  cmp ecx, [esi*4 + TEAMS]
  jne not_friendly
passed:
  mov ax, [ebx + UNIT_NEXT]
  jmp next_unit
all_friendly:
  mov eax, 1
  jmp done
not_friendly:
  xor eax, eax
done:
  pop edi
  pop esi
  pop ebx
  ret
]]

-- isBuildingPlacementAllowedAtTile, the human player's "a unit stands here" branch.
-- ebp = first unit on the tile, [esp+0x24] = the player.
templates.placeTest = [[
  push eax
  push ecx
  push edx
  mov eax, ebp
  mov ecx, [esp + 0x30]
  call TILE_CHECK
  test eax, eax
  pop edx
  pop ecx
  pop eax
  jz refuse
  jmp ALLOW
refuse:
  jmp REFUSE
]]

-- validateWallBuildPath, the "a unit stands here" test. ax = first unit on the tile,
-- [esp+0x34] = the player.
templates.wallTest = [[
  push edx
  movzx eax, ax
  mov ecx, [esp + 0x38]
  call TILE_CHECK
  pop edx
  test eax, eax
  jz refuse
  jmp ALLOW
refuse:
  jmp REFUSE
]]

-- Remember a tile whose units have to be moved. stdcall (tile), eax = 1 if remembered.
templates.queueTile = [[
  mov ecx, [QUEUE]
  cmp ecx, QUEUE_MAX
  jae full
  mov eax, [esp + 4]
  mov [QUEUE + 4 + ecx*4], eax
  add ecx, 1
  mov [QUEUE], ecx
  mov eax, 1
  ret 4
full:
  xor eax, eax
  ret 4
]]

-- placeBuilding, per footprint tile: the game deletes the first unit standing there. The
-- tile is remembered instead and the deletion skipped (ecx = 0 means "no unit").
-- esi = TileMapState, ebx = tile.
templates.placeUnits = [[
  movsx ecx, word [esi + ebx*2 + UNIT_LAYER_OFF]
  test ecx, ecx
  jz resume
  push eax
  push ecx
  push edx
  push ebx
  call QUEUE_TILE
  test eax, eax
  pop edx
  pop ecx
  pop eax
  jz resume
  xor ecx, ecx
resume:
  jmp RESUME
]]

-- placeWalls, per new wall tile. edi = TileMapState, esi = tile.
templates.wallUnits = [[
  movzx eax, word [edi + esi*2 + UNIT_LAYER_OFF]
  test eax, eax
  jz resume
  push eax
  push ecx
  push edx
  push esi
  call QUEUE_TILE
  pop edx
  pop ecx
  pop eax
resume:
  jmp RESUME
]]

-- The end of placeBuilding / placeWalls: move the units, then the function's own epilogue.
templates.epilogue = [[
  cmp dword [QUEUE], 0
  je finish
  pushad
  call DRAIN
  popad
finish:
  pop edi
  pop esi
  pop ebp
  pop ebx
  add esp, FRAME
  ret ARGS
]]

-- validateWallPlacementAtTile (AI walls, crenellations and stairs), once the tile has passed
-- every test: the game removes the unit standing there for some wall types. The tile is
-- remembered instead and ax = 0 skips the removal. edi = TileMapState, esi = tile.
templates.aiWallUnits = [[
  movzx eax, word [edi + esi*2 + UNIT_LAYER_OFF]
  test eax, eax
  jz resume
  push ecx
  push edx
  push esi
  call QUEUE_TILE
  test eax, eax
  pop edx
  pop ecx
  movzx eax, word [edi + esi*2 + UNIT_LAYER_OFF]
  jz resume
  xor eax, eax
resume:
  jmp RESUME
]]

-- The end of placeDefensiveStructureTile: pop edi / ebp / ebx, ret 0x10.
templates.aiWallEpilogue = [[
  cmp dword [QUEUE], 0
  je finish
  pushad
  call DRAIN
  popad
finish:
  pop edi
  pop ebp
  pop ebx
  ret ARGS
]]

return templates
