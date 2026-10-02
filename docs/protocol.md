# Referee link protocol and rules

The board and the browser use the RoboMaster referee serial format. ARCC 2026
uses the **RoboMaster 2026 University Series Communication Protocol V1.3.0**
and the RoboMaster referee hardware (ARCC 2026 Site Manual, table 1-2). Real
referee frames carry their real `cmd_id`. Our own control and console frames
use `0xF0xx`/`0xF1xx`, which the real protocol does not use.

> **Checked against the official document.** Every real frame below was
> compared field by field with *RoboMaster 2026 University Series Communication
> Protocol V1.3.0 (2026-03-27)*: lengths, field order, bit positions, rates,
> robot IDs, and both CRC lookup tables (all 256 entries of each). One
> inconsistency is in the document itself: its command table gives `0x0208` as
> 6 bytes, but its field table and C struct have four `u16` fields (8 bytes).
> We send 8, matching the struct.

## Link

- 115200 baud, 8N1, no flow control (the power management module's User port rate in V1.3.0, table 1-1)
- Path: Chrome Web Serial ⇄ Zybo USB-UART (FTDI) ⇄ PS UART1 ⇄ ARM bridge ⇄
  AXI-Lite ⇄ fabric. The ARM only copies bytes. All parsing, CRCs and rules
  run in the fabric.
- The bridge prints a plain-text banner at boot. It contains no `0xA5`, so
  decoders skip it, and the console shows it under "Raw frames".

## Frame

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | SOF = `0xA5` |
| 1 | 2 | `data_length` (LE) |
| 3 | 1 | `seq` (increments per frame, per direction) |
| 4 | 1 | CRC8 over bytes 0–3 |
| 5 | 2 | `cmd_id` (LE) |
| 7 | n | data |
| 7+n | 2 | CRC16 over bytes 0 to 6+n (LE) |

- CRC8: Dallas/Maxim, reflected polynomial `0x8C`, initial value `0xFF`.
  Table entry [1] = `0x5E`.
- CRC16: CRC-16/MCRF4XX, reflected polynomial `0x8408`, initial value `0xFFFF`.
  Table entry [1] = `0x1189`.
- The board accepts control frames with at most 24 data bytes. Bad frames
  increment the `rx_err` counter in `0xF101`.

## Robot slots

| Slot | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| Robot | red Hero | red Infantry | red Sentry | blue Hero | blue Infantry | blue Sentry |
| robot_id | 1 | 3 | 7 | 101 | 103 | 107 |

1v1 fields only slots 1 and 4; 3v3 fields all six. Each slot's stats come from
`ROBOT_CONFIG`, so the presets live in the console (`web/js/protocol.js`).

## Board → browser: real referee frames (2026 layouts)

These are what the **link robot** would receive: slot 1 (red Infantry) by
default, set in `CONFIG`. A robot's referee parser should accept them as they are.

| cmd_id | Name | Rate | Data |
|---|---|---|---|
| `0x0001` | game_status | 1 Hz + on stage change | `u8` game_type (bits 0–3: 4 = 3v3, 5 = 1v1) \| game_progress (bits 4–7), `u16` stage_remain_time, `u64` SyncTimeStamp |
| `0x0002` | game_result | at round end | `u8` winner: 0 draw, 1 red, 2 blue |
| `0x0003` | game_robot_HP | ~3 Hz | 8 × `u16` **ally** HP: 1, 2, 3, 4, reserved, 7, outpost, base. Hero (1), Infantry (3) and Sentry (7) are filled |
| `0x0101` | event_data | 1 Hz | `u32`: bit 2 own resupply zone occupied, bits 23–24 center point (capture point): 1 ours, 2 enemy, 3 both. 0 in 1v1 |
| `0x0104` | referee_warning | on penalty + 1 Hz | `u8` level (1 both yellow, 2 yellow, 3 red, 4 forfeit), `u8` offending robot_id (0 for both-yellow/forfeit), `u8` count. Own team only |
| `0x0201` | robot_status | 10 Hz | `u8` robot_id, `u8` level, `u16` current_HP, `u16` maximum_HP, `u16` barrel cooling/s, `u16` barrel heat limit, `u16` chassis power limit, `u8` outputs (bit0 gimbal, bit1 chassis, bit2 shooter) |
| `0x0202` | power_heat_data | 10 Hz | `u16` reserved, `u16` reserved, `u32` reserved, `u16` buffer energy J, `u16` 17 mm barrel heat, `u16` 42 mm barrel heat (14 bytes) |
| `0x0204` | buff | ~3 Hz | `u8` recovery % (25 in the resupply zone), `u16` cooling buff, `u8` defence % (100 while invincible), `u8` vulnerability %, `u16` attack %, `u8` remaining energy (0x80) |
| `0x0206` | hurt_data | on hit | `u8` armor_id (bits 0–3) \| reason (bits 4–7): 0 projectile, 1 module offline, 5 collision |
| `0x0207` | shoot_data | on shot | `u8` bullet type (1 = 17 mm, 2 = 42 mm), `u8` shooter number (1 = 17 mm, 3 = 42 mm), `u8` launch frequency Hz, `f32` initial speed m/s |
| `0x0208` | projectile_allowance | 10 Hz | `u16` 17 mm allowance, `u16` 42 mm allowance, `u16` team gold (0 in 1v1), `u16` fortress reserve (0) |
| `0x0209` | rfid_status | ~3 Hz | `u32` cards seen, in battle only: bit 19 own RMUL resupply zone, bit 23 center point (RMUL); `u8` second word (0) |

game_progress values: 0 not started, 1 preparation (setup period), 2 15 s
Referee System self-check, 3 5 s countdown, 4 in battle, 5 settlement.

## Board → browser: console frames

| cmd_id | Name | Rate | Data |
|---|---|---|---|
| `0xF101` | server_state | 10 Hz | 212 bytes, below |
| `0xF102` | server_event | every event | `u8` slot, `u8` kind, `u8` detail, `u16` value (HP after, or projectiles for shots and exchanges) |

`0xF101` layout:

| Offset | Field |
|---|---|
| 0 | `u8` stage (game_progress) |
| 1 | `u8` bit0 paused, bits 1–2 first damaged (1v1: 1 red, 2 blue), bits 3–4 first to fire (1v1), bits 5–6 capture point (0 free, 1 red, 2 blue, 3 contested), bit7 3v3 |
| 2 | `u16` remaining seconds in this stage |
| 4 | `u8` winner, `u8` win reason (1 defeat, 2 more HP, 3 opponent took first damage, 4 more shots, 5 fired first, 6 tie, decided by the referee, 7 forfeit, 8 opponent at 0 VP, 9 more VP, 10 more attack damage, 11 more total HP) |
| 6 | `u8` link slot, `u8` game_type |
| 8 / 16 | red / blue team, 8 bytes: `u16` Victory Points, gold, attack damage dealt; `u8` bit0 the team's 42 mm hits count; `u8` reserved |
| 24 + 30 × slot | robot, 30 bytes: `u16` hp, max_hp, heat ×10, heat_limit, buffer ×0.1 J, power W, power_limit, projectiles, shots fired, cooling/s, speed limit m/s; `u8` yellow cards, flags (bit0 alive, bit1 red card, bit2 shooter on, bit3 chassis on, bit4 gimbal on, bit5 disconnected, bit6 heat-locked, bit7 speed-locked), flags2 (bit0 fielded, bit1 42 mm, bit2 invincible, bit3 weakened, bit4 respawning, bits 5–6 zone: 0 field, 1 resupply, 2 capture point), chassis cut ticks (100 ms); `u16` speed lock ticks (0xFFFF = rest of round), respawn ticks if respawning else invincible ticks |
| 204 | `u16` control frames ok, bad; battle s; setup s |

Event kinds: 1 hit (detail = armor, +0x80 board button, +0x40 collision, +0x20
42 mm), 2 shot, 3 launcher locked, 4 chassis cut, 5 yellow card (detail = count),
6 red card (detail 1 = from three yellows), 7 forfeit, 8 kill, 9 revive,
10 disconnect, 11 reconnect, 12 offline HP loss, 13 launcher unlocked,
14 both-teams yellow, 15 exchange (detail 0 ok, 1 refused), 16 42 mm hit
ignored, 17 respawn (detail = defeats), 18 capture point holder changed (detail
= holder), 19 teammate's yellow (−5 %).

Lock details (kinds 3 and 13): 1 heat, 2 heat over limit + 100 / + 200, 3 speed
15 s, 4 speed 20 s, 5 speed rest of round, 6 out of projectiles.

## Browser → board: control frames

`slot` is 0–5 as above.

| cmd_id | Name | Data |
|---|---|---|
| `0xF001` | GAME | `u8` action: 1 start setup period, 2 skip to referee init, 3 pause (timeout), 4 resume, 5 end round, 6 reset |
| `0xF002` | CONFIG | `u8` game_type (4 = 3v3, 5 = 1v1), `u8` link slot, `u16` battle s, `u16` setup s. **Only while not started.** |
| `0xF009` | ROBOT_CONFIG | `u8` slot, `u8` flags (bit0 fielded, bit1 42 mm launcher), `u16` max HP, heat limit, cooling/s, chassis power limit W, speed limit m/s, initial projectiles (15 bytes). **While not started or in the setup period** (the Infantry pilot picks chassis and launcher types then) |
| `0xF003` | HIT | `u8` slot, `u8` armor 0–3, `u8` kind: 0 17 mm, 1 collision, 2 42 mm |
| `0xF004` | SHOOT | `u8` slot, `u8` frequency, `f32` speed m/s (copied into `0x0207`), `u16` speed in 0.1 m/s (used for the speed-limit check). The slot's caliber decides 17 or 42 mm |
| `0xF005` | PENALTY | `u8` slot, `u8` level: 1 both teams yellow, 2 yellow, 3 red, 4 forfeit (the slot's team) |
| `0xF006` | LIFE | `u8` slot, `u8` 0 kill, 1 revive, 2 abnormal disconnection, 3 reconnect |
| `0xF007` | POWER | `u8` slot, `u16` simulated chassis draw W |
| `0xF008` | TIME | `u32` Unix time (sent by the console on connect) |
| `0xF00A` | ZONE | `u8` slot, `u8` zone: 0 field, 1 own resupply zone, 2 capture point |
| `0xF00B` | EXCHANGE | `u8` slot, `u16` projectiles to buy |

## Rules model (ARCC 2026 Events Manual V1.6)

Robot presets in the console (tables 3-2, 3-3, 3-4, 4-2):

| Robot | HP | Heat limit | Cooling/s | Power W | Speed m/s | Projectiles |
|---|---|---|---|---|---|---|
| 1v1 Infantry | 200 | 80 | 12 | 120 | 25 | 200 |
| 3v3 Hero (42 mm) | 350 | 200 | 24 | 100 | 15 | 0 |
| 3v3 Infantry, HP + Cooldown (default) | 350 | 88 | 24 | 75 | 25 | 0 |
| 3v3 Infantry, Power chassis / Burst launcher | 300 / – | 230 | 14 | 90 / – | 25 | 0 |
| 3v3 Sentry | 400 | 260 | 30 | 100 | 25 | 750 |

Both modes:

| Rule | Manual | Implemented as |
|---|---|---|
| Round flow | 7.4–7.8 | setup period (pausable for timeouts) → 15 s init (HP reset) → 5 s countdown → battle (2 min 1v1, 5 min 3v3) → settlement |
| Attack damage | 3.3.1.1, table 3-7 | 17 mm 20, 42 mm 200, collision 2. Only in an unpaused battle, and only to an alive, connected robot |
| Barrel heat | 3.3.1.3 | +10 per 17 mm / +100 per 42 mm shot; cools cooling/10 every 100 ms. Over the limit locks the launcher until heat = 0; over limit + 100 (17 mm) or + 200 (42 mm) locks it for the round. No HP loss |
| Projectile speed | 3.3.1.2, table 3-8 | 17 mm over by < 5 / < 10 / ≥ 10 m/s, 42 mm up to 1.1× / 1.2× / above: 15 s / 20 s / rest-of-round lock. Locks don't stack (the longer one wins) |
| Chassis power | 3.3.1.4 | buffer 60 J at 10 Hz. Over the limit drains (P − limit)/10 J per tick; when empty the chassis is cut for 5 s. No HP loss |
| Projectiles | 3.3.3, 4.1.1 | each shot uses one; at 0 the launcher is off |
| Abnormal disconnection | 3.3.1.5.1 | outputs off, damage not detected, −5 % max HP per second, respawn paused |
| Yellow card | 8.1.2 | −15 % max HP, doubled for each repeat within 30 s; never below 1 HP; the third yellow is a red card. 3v3: alive teammates −5 %, and a Sentry's chassis is cut for 2 s. Both teams yellow: −5 % to every robot |
| Red card | 8.1.2 | HP → 0, ejected (no respawn) |

1v1 only (section 4):

| Rule | Manual | Implemented as |
|---|---|---|
| Forfeit | 8.1.2 | before battle: offender 0 HP, other full; during battle: HP kept. Other side wins |
| Winning | 4.4 | a defeat ends the round. At time-out: more HP → did not take the first damage → more shots → fired first → otherwise a tie (the referee decides by weight) |

3v3 only (section 3):

| Rule | Manual | Implemented as |
|---|---|---|
| Victory Points | 3.3.4 | 200 each. The team holding the capture point drains the enemy 1 VP/s; each defeat costs 20 VP; 0 VP ends the round |
| Capture point | 3.3.4 | held by the team with an alive, connected, non-weakened robot there; a holder keeps it while present; both teams with no holder = contested. The ZONE command stands in for the RFID card |
| Respawn | 3.3.2.2 | 5 s after the first defeat, +5 s per further defeat; at 20 % HP, invincible 30 s and weakened (launcher locked, can't capture) until the robot is in its resupply zone; heat and buffer reset on defeat |
| Resupply zone | 3.3.2.1 | +25 % max HP per second; clears weakened and invincible |
| Gold | 3.3.3, table 3-10 | 200 at the start, +200 at 3:59 and 2:59, +300 at 1:59 and 0:59; +200 to the trailing team the first time the VP gap reaches 70 and 140 |
| Exchange | 3.3.3, table 3-11 | Hero or Infantry in its resupply zone during battle: 17 mm 1 gold each, 42 mm 10 gold each |
| 42 mm immunity | 3.3.1.1, 3.3.3 | 42 mm hits do nothing while the attacking team's Hero hasn't fired for 4 s, or has been down or offline for 3 s |
| Forfeit | 8.1.2 | forfeiting team's VP → 0; round ends |
| Winning | 3.3.5 | 0 VP ends it. At time-out: more VP → more attack damage dealt (hits and penalties) → more total HP → otherwise a tie |

**Not modelled:** the 2/5 s pilot UI blackout after a yellow card, the 2 s RFID
expiry on leaving the capture point, the Hero allowance-overrun immunity case,
armor detection intervals and speed thresholds, Speed Monitor / Armor Module
disconnection, and the "temporarily activated" state.

## Board buttons and LEDs

| Item | Function |
|---|---|
| BTN0–3 | 17 mm hit on armor plate 0–3 (front, left, back, right) |
| SW0 | team the buttons hit: down = red, up = blue |
| SW2:1 | robot the buttons hit: 00 Infantry, 01 Hero, 10 Sentry |
| LD0 | battle running (blinks while paused) |
| LD1 / LD2 | some red / blue robot alive |
| LD3 | flashes on each accepted control frame |

## AXI registers (`0x43C00000`)

| Offset | Register |
|---|---|
| `0x00` | ID `0x41524346` ("ARCF") |
| `0x04` | version |
| `0x08` | RX_DATA (write a byte from the browser) |
| `0x0C` | TX_DATA (read: bit 8 valid, bits 7–0 byte; pops) |
| `0x10` | STATUS: TX FIFO level, bit 16 empty |
| `0x14` | CTRL: bit 0 soft reset |
| `0x18` | control frames ok (bits 15–0) / bad (bits 31–16) |
| `0x1C` | debounced buttons (bits 3–0) and switches (bits 7–4) |
