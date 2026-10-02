--[[
  Build Over Workers

  1. The player may place buildings and walls on tiles where friendly workers stand (his own,
     and his allies' if that is switched on). Soldiers and enemy units still block, as before.
     The game's test is one branch in isBuildingPlacementAllowedAtTile (buildings) and one
     in validateWallBuildPath (walls); both only let chickens through for a human player.
  2. Anyone caught under a new building or wall is moved to the nearest free ground tile
     next to it, and sent on to where they were going. Before, placeBuilding deleted the
     first unit on each footprint tile (for most building types) and left the rest inside,
     where the game removes them later. Every footprint tile with units on it is remembered
     while the game places the building, and the units are moved once it is done.
  3. The same for the AI. AI buildings already go through placeBuilding; AI walls,
     crenellations and stairs are laid tile by tile through placeDefensiveStructureTile,
     whose check (validateWallPlacementAtTile) removed the unit on the tile for some wall
     types and left it inside the wall for the others.

  Every address is found by pattern scan or read out of the instruction that uses it, so the
  module runs on Stronghold Crusader.exe and Stronghold_Crusader_Extreme.exe alike.
]]

local templates = require("templates")

local MODULE_NAME = "build-over-workers"

local DEFAULTS = { buildings = true, walls = true, allies = true }

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module touches it
---------------------------------------------------------------------------------------

-- isBuildingPlacementAllowedAtTile, human branch: imul ebp,ebp,0x490 / cmp word
-- [ebp+unitType],0x3E (chicken) / jne refuse.
local AOB_PLACE_TEST = "69 ED 90 04 00 00 66 83 BD ? ? ? ? 3E 0F 85 ? ? ? ? 8B 54 24 28"
local PLACE_TEST_SIZE = 20
-- validateWallBuildPath: the same test for walls, at +8.
local AOB_WALL_TEST = "F7 C1 00 01 00 00 75 17 0F BF C8 69 C9 90 04 00 00 66 83 B9 ? ? ? ? 3E 0F 85"
local WALL_TEST_HOOK = 8
local WALL_TEST_SIZE = 23
-- placeBuilding, per footprint tile: movsx ecx, word [esi+ebx*2+unitLayer].
local AOB_PLACE_UNITS = "0F BF 8C 5E E0 D7 23 00 85 C9 74 26 0F BF 44 24 28 83 C0 D3"
-- placeWalls, per new wall tile: movzx eax, word [edi+esi*2+unitLayer].
local AOB_WALL_UNITS = "0F B7 84 77 E0 D7 23 00 66 85 C0 74 2A 0F BF C0 69 C0 90 04 00 00 66 83 B8"
local UNITS_SIZE = 8
-- The two epilogues: pop edi/esi/ebp/ebx, add esp,N, ret M.
local AOB_PLACE_END = "C7 86 7C 48 55 00 C8 00 00 00 5F 5E 5D 5B 83 C4 08 C2 18 00"
local PLACE_END = { hook = 10, frame = 0x08, args = 0x18 }
local AOB_WALL_END = "A3 ? ? ? ? E8 ? ? ? ? 5F 5E 5D 5B 83 C4 28 C2 1C 00"
local WALL_END = { hook = 10, frame = 0x28, args = 0x1C }
local EPILOGUE_SIZE = 10
-- AI walls: validateWallPlacementAtTile's unit test, after every other test has passed, and
-- the end of placeDefensiveStructureTile (pop edi/ebp/ebx, ret 0x10).
local AOB_AI_WALL_UNITS = "0F B7 84 77 E0 D7 23 00 66 85 C0 74 30 F7 84 B7 60 51 16 00 00 01 00 00"
local AOB_AI_WALL_END = "C7 05 ? ? ? ? 01 00 00 00 E8 ? ? ? ? 5F 5D 5B C2 10 00"
local AI_WALL_END = { hook = 15, args = 0x10, size = 6 }

-- UnitsState::setPositionOfUnit(unit, x, y, height) and the two tables it reads.
local AOB_SET_POSITION = "53 8B 5C 24 0C 81 FB 8F 01 00 00 55 8B E9 0F 87"
local SET_POSITION_VALID = { 0x2F, { 0x38, 0x8C, 0x18 } }     -- cmp [eax+ebx+validTiles], cl
local SET_POSITION_ROWS = { 0xBE, { 0x03, 0x0C, 0x85 } }      -- add ecx, [eax*4+rows]
-- UnitsState::setDestinationForUnit(unit, x, y, reuse). Its first bytes are patched by
-- other modules, so the pattern starts 0x11 in.
local AOB_SET_DESTINATION = "8B 6C 24 18 56 8D 34 0A 0F BF 96 A2 06 00 00"
local SET_DESTINATION_START = 0x11
local SET_DESTINATION_AREAS = { 0x160, { 0x0F, 0xBF, 0x14, 0x45 } }

-- The tile flags (one dword per tile), the first array of TileMapState that has a global.
local AOB_TILE_FLAGS = "F7 04 9D ? ? ? ? 00 01 00 00"
local TILE_FLAGS_OPERAND = 3
local AOB_PLAYER_TEAMS = "8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?"
local PLAYER_TEAMS_OPERAND = 3
local PLAYERS = 8

-- TileMapState layout (OpenSHC, the same in both exes).
local TMS_FLAGS = 0x165160
local TMS_BUILDINGS = 0x2029B0
local TMS_UNITS = 0x23D7E0
local TMS_HEIGHTS = 0x29FA30
local TMS_AREAS = 0x363ED0
local TMS_LINKS = 0x38B2F0

-- Unit layout.
local UNIT_SIZE = 0x490
local UNITS_FROM_STATE = 0x614
local U_STATE = 0x8C
local U_TYPE = 0x8E
local U_OWNER = 0x96
local U_X = 0xC4
local U_Y = 0xC6
local U_TILE = 0xD4
local U_DEST_X = 0xEC
local U_DEST_Y = 0xEE
local U_MOVING = 0xF6
local U_NEXT = 0x2A2

-- Tile flags: wall, crenellation, stairs; 0x30 and 0x10000000 the game refuses as a
-- destination.
local FLAGS_NOT_GROUND = 0x10000B30

-- Unit types (OpenSHC's UnitType) that count as workers: peasants, every workshop, farm,
-- quarry, mine and inn worker, priest, healer, drunk, trader, fireman, lady, jester,
-- mothers, children, jugglers and fire eaters. Not tunnelers, engineers or any soldier.
local TYPE_COUNT = 80
local WORKER_TYPES = { 1, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
  31, 32, 33, 34, 35, 36, 42, 43, 53, 56, 57, 63, 64, 65, 66 }
local CHICKEN = 62

local QUEUE_MAX = 1024
local SEARCH_RADIUS = 16
local MAP_SIZE = 400

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local function scan(pattern, purpose)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok or address == nil then
    error(MODULE_NAME .. ": could not find " .. purpose)
  end
  return address
end

local function expectBytes(address, bytes, purpose)
  for index, byte in ipairs(bytes) do
    if (core.readByte(address + index - 1) & 0xFF) ~= byte then
      error(string.format("%s: %s at 0x%X is not the code this module knows", MODULE_NAME,
        purpose, address))
    end
  end
end

local function readOperand(base, site, purpose)
  expectBytes(base + site[1], site[2], purpose)
  return core.readInteger(base + site[1] + #site[2])
end

-- FASM gets a fixed 64 KB for source, symbols and output: only pass what a script uses.
local function assemble(script, values)
  local used = {}
  for name, value in pairs(values) do
    if script:find("%f[%w_]" .. name .. "%f[^%w_]") then
      used[name] = value
    end
  end
  return core.allocateAssembly(script, used)
end

local function jumpTo(address, target, size)
  local code = { 0xE9, core.itob(core.getRelativeAddress(address, target, -5)) }
  for _ = 6, size do
    code[#code + 1] = 0x90
  end
  core.writeCode(address, code)
end

local function setting(config, name)
  if type(config) == "table" and config[name] ~= nil then
    return config[name] == true
  end
  return DEFAULTS[name]
end

local function word(address)
  return core.readSmallInteger(address) & 0xFFFF
end

local function signedWord(address)
  local value = word(address)
  if value >= 0x8000 then value = value - 0x10000 end
  return value
end

-- A cdecl function with no arguments that runs `callback` in lua.
local function luaFunction(purpose, callback)
  local pad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
  local reported = false
  core.detourCode(function(registers)
    local ok, message = pcall(callback)
    if not ok and not reported then
      reported = true
      log(WARNING, string.format("%s: %s failed: %s", MODULE_NAME, purpose, tostring(message)))
    end
    return registers
  end, pad, 5)
  return pad
end

---------------------------------------------------------------------------------------
-- Moving the units
---------------------------------------------------------------------------------------

-- Offsets around a tile, nearest first, so the first free one is the closest.
local function nearestFirst(radius)
  local offsets = {}
  for dy = -radius, radius do
    for dx = -radius, radius do
      if dx ~= 0 or dy ~= 0 then
        offsets[#offsets + 1] = { dx, dy, dx * dx + dy * dy }
      end
    end
  end
  table.sort(offsets, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  return offsets
end

local function makeDrain(m)
  local offsets = nearestFirst(SEARCH_RADIUS)
  local setPosition = core.exposeCode(m.setPosition, 5, 1)
  local setDestination = core.exposeCode(m.setDestination, 5, 1)

  local function tileOf(x, y)
    return core.readInteger(m.rows + 12 * y) + x
  end

  -- A new building or wall stands on the tile.
  local function builtOver(tile)
    return word(m.tms + TMS_BUILDINGS + 2 * tile) ~= 0
      or (core.readInteger(m.tms + TMS_FLAGS + 4 * tile) & 0xB00) ~= 0
  end

  -- Open ground a unit can stand on and walk away from.
  local function freeGround(x, y)
    if x < 0 or y < 0 or x >= MAP_SIZE or y >= MAP_SIZE then return nil end
    if (core.readByte(m.valid + y * MAP_SIZE + x) & 0xFF) == 0 then return nil end
    local tile = tileOf(x, y)
    if word(m.tms + TMS_BUILDINGS + 2 * tile) ~= 0 then return nil end
    if (core.readInteger(m.tms + TMS_FLAGS + 4 * tile) & FLAGS_NOT_GROUND) ~= 0 then return nil end
    if (core.readByte(m.tms + TMS_LINKS + tile) & 0xFF) == 0 then return nil end
    return tile
  end

  -- The nearest free tile, on the same side of any wall as the unit if there is one.
  local function findSpot(x, y, area)
    local passes = area ~= 0 and { true, false } or { false }
    for _, sameArea in ipairs(passes) do
      for _, o in ipairs(offsets) do
        local nx, ny = x + o[1], y + o[2]
        local tile = freeGround(nx, ny)
        if tile ~= nil and (not sameArea or word(m.tms + TMS_AREAS + 2 * tile) == area) then
          return nx, ny, tile
        end
      end
    end
    return nil
  end

  local function moveUnit(unit)
    local base = m.units + unit * UNIT_SIZE
    local x, y = signedWord(base + U_X), signedWord(base + U_Y)
    local area = word(m.tms + TMS_AREAS + 2 * core.readInteger(base + U_TILE))
    local nx, ny, tile = findSpot(x, y, area)
    if nx == nil then return end
    local moving = word(base + U_MOVING) ~= 0
    local destX, destY = signedWord(base + U_DEST_X), signedWord(base + U_DEST_Y)
    setPosition(m.unitsState, unit, nx, ny, core.readByte(m.tms + TMS_HEIGHTS + tile) & 0xFF)
    if moving and destX >= 0 and destY >= 0 and destX < MAP_SIZE and destY < MAP_SIZE
        and (destX ~= nx or destY ~= ny) then
      setDestination(m.unitsState, unit, destX, destY, 0)
    end
  end

  return function()
    local count = core.readInteger(m.queue)
    core.writeInteger(m.queue, 0)
    for index = 0, math.min(count, QUEUE_MAX) - 1 do
      local tile = core.readInteger(m.queue + 4 + 4 * index)
      if builtOver(tile) then
        local unit = word(m.tms + TMS_UNITS + 2 * tile)
        local guard = 64
        while unit ~= 0 and guard > 0 do
          guard = guard - 1
          local base = m.units + unit * UNIT_SIZE
          local nextUnit = word(base + U_NEXT)
          if word(base + U_STATE) ~= 0 then
            moveUnit(unit)
          end
          unit = nextUnit
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------------------

local function enable(self, config)
  local buildings = setting(config, "buildings")
  local walls = setting(config, "walls")
  local allies = setting(config, "allies")

  local placeTest = scan(AOB_PLACE_TEST, "the building placement test")
  local wallTest = scan(AOB_WALL_TEST, "the wall placement test")
  local placeUnits = scan(AOB_PLACE_UNITS, "where a new building meets units")
  local wallUnits = scan(AOB_WALL_UNITS, "where a new wall meets units")
  local placeEnd = scan(AOB_PLACE_END, "the end of building placement") + PLACE_END.hook
  local wallEnd = scan(AOB_WALL_END, "the end of wall placement") + WALL_END.hook
  local aiWallUnits = scan(AOB_AI_WALL_UNITS, "where an AI wall meets units")
  local aiWallEnd = scan(AOB_AI_WALL_END, "the end of AI wall placement") + AI_WALL_END.hook
  local setPos = scan(AOB_SET_POSITION, "where a unit is put down")
  local setDest = scan(AOB_SET_DESTINATION, "the unit route search") - SET_DESTINATION_START
  local flags = core.readInteger(scan(AOB_TILE_FLAGS, "the tile flags") + TILE_FLAGS_OPERAND)

  local units = core.readInteger(placeTest + 9) - U_TYPE
  local tms = flags - TMS_FLAGS
  if core.readInteger(wallTest + 20) - U_TYPE ~= units then
    error(MODULE_NAME .. ": the unit layout is not the one this module knows")
  end
  if readOperand(setDest, SET_DESTINATION_AREAS, "the area map") ~= tms + TMS_AREAS then
    error(MODULE_NAME .. ": the tile map layout is not the one this module knows")
  end

  local data = core.allocate(8 + 4 + 4 * QUEUE_MAX + TYPE_COUNT, true)
  local m = {
    allies = data,
    queue = data + 8,
    workers = data + 8 + 4 + 4 * QUEUE_MAX,
    units = units,
    unitsState = units - UNITS_FROM_STATE,
    tms = tms,
    valid = readOperand(setPos, SET_POSITION_VALID, "the map's valid tiles"),
    rows = readOperand(setPos, SET_POSITION_ROWS, "the map rows"),
    setPosition = setPos,
    setDestination = setDest,
  }
  core.writeByte(m.allies, allies and 1 or 0)
  for _, unitType in ipairs(WORKER_TYPES) do
    core.writeByte(m.workers + unitType, 1)
  end

  -- 1. Building over friendly workers.
  if buildings or walls then
    local teams
    if allies then
      teams = core.readInteger(scan(AOB_PLAYER_TEAMS, "the player teams") + PLAYER_TEAMS_OPERAND)
    else
      teams = core.allocate((PLAYERS + 1) * 4, true)
    end
    local check = assemble(templates.tileCheck, {
      UNIT_TYPE = units + U_TYPE,
      UNIT_OWNER = units + U_OWNER,
      UNIT_NEXT = units + U_NEXT,
      CHICKEN = CHICKEN,
      TYPE_COUNT = TYPE_COUNT,
      WORKERS = m.workers,
      ALLIES = m.allies,
      PLAYERS = PLAYERS,
      TEAMS = teams,
    })
    if buildings then
      local refuse = placeTest + 20 + core.readInteger(placeTest + 16)
      local code = assemble(templates.placeTest, {
        TILE_CHECK = check, ALLOW = placeTest + PLACE_TEST_SIZE, REFUSE = refuse,
      })
      jumpTo(placeTest, code, PLACE_TEST_SIZE)
    end
    if walls then
      local site = wallTest + WALL_TEST_HOOK
      local refuse = site + WALL_TEST_SIZE + core.readInteger(site + WALL_TEST_SIZE - 4)
      local code = assemble(templates.wallTest, {
        TILE_CHECK = check, ALLOW = site + WALL_TEST_SIZE, REFUSE = refuse,
      })
      jumpTo(site, code, WALL_TEST_SIZE)
    end
  end

  -- 2. Moving whoever ends up under a new building or wall.
  local queueTile = assemble(templates.queueTile, { QUEUE = m.queue, QUEUE_MAX = QUEUE_MAX })
  local drain = luaFunction("moving units out of a new building", makeDrain(m))

  jumpTo(placeUnits, assemble(templates.placeUnits, {
    UNIT_LAYER_OFF = TMS_UNITS, QUEUE_TILE = queueTile, RESUME = placeUnits + UNITS_SIZE,
  }), UNITS_SIZE)
  jumpTo(wallUnits, assemble(templates.wallUnits, {
    UNIT_LAYER_OFF = TMS_UNITS, QUEUE_TILE = queueTile, RESUME = wallUnits + UNITS_SIZE,
  }), UNITS_SIZE)
  for _, e in ipairs({ { placeEnd, PLACE_END }, { wallEnd, WALL_END } }) do
    jumpTo(e[1], assemble(templates.epilogue, {
      QUEUE = m.queue, DRAIN = drain, FRAME = e[2].frame, ARGS = e[2].args,
    }), EPILOGUE_SIZE)
  end

  -- 3. The AI's walls, laid tile by tile.
  jumpTo(aiWallUnits, assemble(templates.aiWallUnits, {
    UNIT_LAYER_OFF = TMS_UNITS, QUEUE_TILE = queueTile, RESUME = aiWallUnits + UNITS_SIZE,
  }), UNITS_SIZE)
  jumpTo(aiWallEnd, assemble(templates.aiWallEpilogue, {
    QUEUE = m.queue, DRAIN = drain, ARGS = AI_WALL_END.args,
  }), AI_WALL_END.size)
end

return {
  enable = enable,
  disable = function(self, config) end,
}
