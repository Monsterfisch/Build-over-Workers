"""Runs build-over-workers unchanged in the emulator on both exes. Addresses are found here
independently of the module."""
import struct
from harness import Host, SENTINEL, MASK, STACK_TOP

FAILS = []
COUNT = [0]


def check(label, got, want):
    COUNT[0] += 1
    if got != want:
        FAILS.append(label)
        print('  FAIL %s: got %r want %r' % (label, got, want))


class Stop(Exception):
    pass


def target(H, site):
    assert H.m.read(site, 1)[0] == 0xE9, hex(site)
    return (site + 5 + H.m.s32(site + 1)) & MASK


def suite(ext, config=None):
    H = Host(extreme=ext, config=config or {})
    E = H.E
    f = lambda p: E.find(p)[0]
    placeTest = f('69 ED 90 04 00 00 66 83 BD ? ? ? ? 3E 0F 85 ? ? ? ? 8B 54 24 28')
    wallTest = f('F7 C1 00 01 00 00 75 17 0F BF C8 69 C9 90 04 00 00 66 83 B9 ? ? ? ? 3E 0F 85') + 8
    placeUnits = f('0F BF 8C 5E E0 D7 23 00 85 C9 74 26 0F BF 44 24 28 83 C0 D3')
    wallUnits = f('0F B7 84 77 E0 D7 23 00 66 85 C0 74 2A 0F BF C0 69 C0 90 04 00 00 66 83 B8')
    placeEnd = f('C7 86 7C 48 55 00 C8 00 00 00 5F 5E 5D 5B 83 C4 08 C2 18 00') + 10
    wallEnd = f('A3 ? ? ? ? E8 ? ? ? ? 5F 5E 5D 5B 83 C4 28 C2 1C 00') + 10
    setPos = f('53 8B 5C 24 0C 81 FB 8F 01 00 00 55 8B E9 0F 87')
    setDest = f('8B 6C 24 18 56 8D 34 0A 0F BF 96 A2 06 00 00') - 0x11
    TMS = E.u32(f('F7 04 9D ? ? ? ? 00 01 00 00') + 3) - 0x165160
    TEAMS = E.u32(f('8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?') + 3)
    UNITS = E.u32(placeTest + 9) - 0x8E
    ROWS = E.u32(setPos + 0xC1)
    VALID = E.u32(setPos + 0x32)
    allow_p, refuse_p = placeTest + 20, placeTest + 20 + E.i32(placeTest + 16)
    allow_w, refuse_w = wallTest + 23, wallTest + 23 + E.i32(wallTest + 19)
    tag = 'EXT' if ext else 'VAN'
    unit = lambda i: UNITS + i * 0x490

    def mkunit(i, utype, owner, nxt=0, x=0, y=0, state=1):
        u = unit(i)
        H.put16(u + 0x8C, state); H.put16(u + 0x8E, utype); H.put16(u + 0x96, owner)
        H.put16(u + 0x2A2, nxt); H.put16(u + 0xC4, x); H.put16(u + 0xC6, y)
        H.put32(u + 0xD4, y * 400 + x)

    def stopper(cpu, where):
        def hook(c):
            H.where = where
            c.eip = SENTINEL
        return hook

    patched = target(H, placeTest) if config.get('buildings', True) is not False else None

    # 1. the building test
    if config.get('buildings', True) is not False:
        H.cpu.hooks[allow_p] = stopper(H.cpu, 'allow')
        H.cpu.hooks[refuse_p] = stopper(H.cpu, 'refuse')
        for label, units, player, teams, want in [
            ('own woodcutter', [(5, 3, 1, 0)], 1, (0, 0), 'allow'),
            ('own worker + own spearman', [(5, 3, 1, 6), (6, 24, 1, 0)], 1, (0, 0), 'refuse'),
            ('own spearman', [(5, 24, 1, 0)], 1, (0, 0), 'refuse'),
            ('allied worker', [(5, 11, 2, 0)], 1, (1, 1), 'allow' if config.get('allies', True) else 'refuse'),
            ('enemy worker', [(5, 11, 3, 0)], 1, (1, 2), 'refuse'),
            ('no-team worker', [(5, 11, 2, 0)], 1, (0, 0), 'refuse'),
            ('chicken', [(5, 62, 0, 0)], 1, (0, 0), 'allow'),
            ('own tunneler', [(5, 5, 1, 0)], 1, (0, 0), 'refuse'),
            ('own lord', [(5, 55, 1, 0)], 1, (0, 0), 'refuse'),
        ]:
            for i, t, o, n in units:
                mkunit(i, t, o, n)
            H.put32(TEAMS + 4 * 1, teams[0]); H.put32(TEAMS + 4 * player, teams[0])
            other = units[0][2]
            if other != player:
                H.put32(TEAMS + 4 * other, teams[1])
            H.where = None
            regs = dict(eax=0x11, ecx=0x22, edx=0x33, ebx=0x44, esi=0x55, edi=0x66, ebp=units[0][0])
            stack = [0] * 8 + [player]
            cpu = H.run(placeTest, regs=regs, stack=stack)
            check('%s place %s' % (tag, label), H.where, want)
            check('%s place %s regs' % (tag, label),
                  [cpu.r[r] for r in ('eax', 'ecx', 'edx', 'ebx', 'esi', 'edi')],
                  [0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
            check('%s place %s stack' % (tag, label), cpu.r['esp'], STACK_TOP - 4 * 10)

    # 2. the wall test
    if config.get('walls', True) is not False:
        H.cpu.hooks[allow_w] = stopper(H.cpu, 'allow')
        H.cpu.hooks[refuse_w] = stopper(H.cpu, 'refuse')
        for label, units, want in [
            ('own baker', [(7, 16, 1, 0)], 'allow'),
            ('own archer', [(7, 22, 1, 0)], 'refuse'),
            ('enemy peasant', [(7, 1, 4, 0)], 'refuse'),
        ]:
            for i, t, o, n in units:
                mkunit(i, t, o, n)
            H.put32(TEAMS + 4 * 4, 3)
            H.where = None
            regs = dict(eax=units[0][0], ecx=0x22, edx=0x33, ebx=0x44, esi=0x55, edi=0x66, ebp=0x77)
            cpu = H.run(wallTest, regs=regs, stack=[0] * 12 + [1])
            check('%s wall %s' % (tag, label), H.where, want)
            check('%s wall %s regs' % (tag, label),
                  [cpu.r[r] for r in ('edx', 'ebx', 'esi', 'edi', 'ebp')], [0x33, 0x44, 0x55, 0x66, 0x77])

    # 3. remembering the tiles
    epi = target(H, placeEnd)
    QUEUE = H.m.u32(epi + 2)
    check('%s epilogue shape' % tag, H.m.read(epi, 2), b'\x83\x3D')
    H.cpu.hooks[placeUnits + 8] = stopper(H.cpu, 'resume')
    tile = 100 * 400 + 100
    H.put16(TMS + 0x23D7E0 + 2 * tile, 5)
    cpu = H.run(placeUnits, regs=dict(esi=TMS, ebx=tile, eax=0x11, edx=0x33, edi=0x66, ebp=0x77))
    check('%s queue place' % tag, (H.where, cpu.r['ecx'], H.u32(QUEUE), H.u32(QUEUE + 4)), ('resume', 0, 1, tile))
    check('%s queue place regs' % tag, [cpu.r[r] for r in ('eax', 'edx', 'ebx', 'esi', 'edi', 'ebp')],
          [0x11, 0x33, tile, TMS, 0x66, 0x77])
    H.put16(TMS + 0x23D7E0 + 2 * (tile + 1), 0)
    cpu = H.run(placeUnits, regs=dict(esi=TMS, ebx=tile + 1))
    check('%s queue place empty' % tag, (cpu.r['ecx'], H.u32(QUEUE)), (0, 1))
    H.cpu.hooks[wallUnits + 8] = stopper(H.cpu, 'resume')
    cpu = H.run(wallUnits, regs=dict(edi=TMS, esi=tile, ecx=0x22, edx=0x33))
    check('%s queue wall' % tag, (cpu.r['eax'], cpu.r['ecx'], cpu.r['edx'], H.u32(QUEUE), H.u32(QUEUE + 8)),
          (5, 0x22, 0x33, 2, tile))
    H.put32(QUEUE, 0)

    # 4. moving the units at the end
    for y in range(400):
        H.put32(ROWS + y * 12, y * 400)
    for y in range(80, 121):
        for x in range(80, 121):
            t = y * 400 + x
            H.put8(VALID + y * 400 + x, 1)
            H.put8(TMS + 0x38B2F0 + t, 0xFF)
            H.put16(TMS + 0x363ED0 + 2 * t, 1)
            H.put8(TMS + 0x29FA30 + t, 9)
    for y in range(99, 102):
        for x in range(99, 102):
            H.put16(TMS + 0x2029B0 + 2 * (y * 400 + x), 7)
    H.put16(TMS + 0x363ED0 + 2 * (98 * 400 + 100), 2)      # other side of a wall
    mkunit(5, 3, 1, 6, 100, 100)
    mkunit(6, 24, 2, 0, 100, 100)
    H.put16(unit(5) + 0xF6, 1); H.put16(unit(5) + 0xEC, 120); H.put16(unit(5) + 0xEE, 100)
    H.put16(unit(6) + 0xF6, 0)
    H.put16(TMS + 0x23D7E0 + 2 * tile, 5)
    H.put32(QUEUE, 2); H.put32(QUEUE + 4, tile); H.put32(QUEUE + 8, 300 * 400 + 300)

    def set_position(this, u, x, y, h):
        H.put16(unit(u) + 0xC4, x); H.put16(unit(u) + 0xC6, y)
        return 0
    H.exposed = {setPos: set_position}
    H.calls = []
    cpu = H.cpu
    cpu.r['esp'] = STACK_TOP
    for v in [0xA6, 0xA5, 0xA4, 0xA3, 0xA2, 0xA1]:
        cpu.push(v)
    cpu.push(SENTINEL)
    cpu.push(0xF2); cpu.push(0xF1)
    for v in (0xBB, 0xBE, 0x51, 0xD1):     # ebx, ebp, esi, edi (popped edi first)
        cpu.push(v)
    cpu.r.update(eax=0x1111, ecx=0x2222, edx=0x3333)
    cpu.count = 0
    cpu.eip = placeEnd
    cpu.run(SENTINEL, 2_000_000)
    check('%s drain logs' % tag, [l for l in H.logs if 'failed' in l], [])
    check('%s drain calls' % tag, H.calls, [
        (setPos, [UNITS - 0x614, 5, 98, 100, 9]),
        (setDest, [UNITS - 0x614, 5, 120, 100, 0]),
        (setPos, [UNITS - 0x614, 6, 98, 100, 9]),
    ])
    check('%s drain regs' % tag, [cpu.r[r] for r in ('eax', 'ecx', 'edx', 'ebx', 'ebp', 'esi', 'edi', 'esp')],
          [0x1111, 0x2222, 0x3333, 0xBB, 0xBE, 0x51, 0xD1, STACK_TOP])
    check('%s drain emptied' % tag, H.u32(QUEUE), 0)

    # nothing queued: straight through
    H.calls = []
    cpu.r['esp'] = STACK_TOP
    for v in range(7):
        cpu.push(0)
    cpu.push(SENTINEL)
    for v in range(1 + 0x28 // 4 + 3):
        cpu.push(0)
    cpu.eip = wallEnd
    cpu.run(SENTINEL, 100000)
    check('%s wall end empty' % tag, (H.calls, cpu.r['esp']), ([], STACK_TOP - 4 * 7 + 0x1C))

    # 5. AI walls: validateWallPlacementAtTile from the unit test to its return, then the end
    # of placeDefensiveStructureTile
    aiUnits = f('0F B7 84 77 E0 D7 23 00 66 85 C0 74 30 F7 84 B7 60 51 16 00 00 01 00 00')
    aiEnd = f('C7 05 ? ? ? ? 01 00 00 00 E8 ? ? ? ? 5F 5D 5B C2 10 00') + 15
    check('%s ai hooks' % tag, (H.m.read(aiUnits, 1), H.m.read(aiEnd, 1)), (b'\xE9', b'\xE9'))
    wt = 110 * 400 + 110
    mkunit(8, 24, 3, 0, 110, 110)
    H.put16(unit(8) + 0xF6, 0)
    H.put16(TMS + 0x23D7E0 + 2 * wt, 8)

    def run_validate(mapper):
        cpu.r['esp'] = STACK_TOP
        for v in (mapper, 110, 110, 2):
            cpu.push(v)
        cpu.push(SENTINEL)
        for v in (0xBB, 0xBE, 0x51, 0xD1):
            cpu.push(v)
        cpu.r.update(edi=TMS, esi=wt, ecx=0x2222, edx=0x3333)
        H.put32(TMS + 0x55491C, 1)
        cpu.count = 0
        cpu.eip = aiUnits
        cpu.run(SENTINEL, 100000)
        return cpu

    H.put32(QUEUE, 0)
    cpu = run_validate(0x1A)
    check('%s ai wall kept' % tag, (H.u16(unit(8) + 0x8C), H.u32(QUEUE), H.u32(QUEUE + 4)), (1, 1, wt))
    check('%s ai wall valid' % tag, (H.u32(TMS + 0x55491C), cpu.r['esp'], cpu.r['ebx'], cpu.r['ebp'],
                                     cpu.r['esi'], cpu.r['edi']), (0, STACK_TOP, 0xBB, 0xBE, 0x51, 0xD1))
    H.put32(QUEUE, 1024)
    run_validate(0x1A)
    check('%s ai wall full queue: game removes' % tag, H.u16(unit(8) + 0x8C), 3)
    H.put16(unit(8) + 0x8C, 1)

    H.put32(QUEUE, 1); H.put32(QUEUE + 4, wt)
    H.put32(TMS + 0x165160 + 4 * wt, 0x100)
    H.calls = []
    cpu.r['esp'] = STACK_TOP
    for v in range(4):
        cpu.push(0)
    cpu.push(SENTINEL)
    for v in (0xBB, 0xBE, 0xD1):
        cpu.push(v)
    cpu.r.update(eax=0x1111, esi=0x5151)
    cpu.count = 0
    cpu.eip = aiEnd
    cpu.run(SENTINEL, 2_000_000)
    check('%s ai wall drain' % tag, H.calls, [(setPos, [UNITS - 0x614, 8, 110, 109, 9])])
    check('%s ai wall drain regs' % tag, [cpu.r[r] for r in ('eax', 'esi', 'ebx', 'ebp', 'edi', 'esp')],
          [0x1111, 0x5151, 0xBB, 0xBE, 0xD1, STACK_TOP])
    return H


for ext in (False, True):
    suite(ext, {})
    suite(ext, {'allies': False})
    suite(ext, {'buildings': False, 'walls': False})
print('%d checks, %d failed' % (COUNT[0], len(FAILS)))
