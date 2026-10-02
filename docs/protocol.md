# Referee link protocol and rules

The board and the browser use the RoboMaster referee serial format. ARCC 2026
uses the **RoboMaster 2026 University Series Communication Protocol V1.3.0**
and the RoboMaster referee hardware (ARCC 2026 Site Manual, table 1-2). Real
referee frames carry their real `cmd_id`. Our own control and console frames
use `0xF0xx`/`0xF1xx`, which the real protocol does not use.

> **Where the layouts come from.** The official V1.3.0 PDF could not be
> downloaded from this environment. The 2026 layouts below were taken from
> [rm-proto](https://github.com/Salfa-04/rm-proto), an open-source
> implementation of the 2026 protocol V1.2.0. `0x0207` is not in that library
> and still uses the older V1.6 layout. Check everything against V1.3.0 and
> update `hw/rtl/arc_frame_gen.v`, `web/js/protocol.js` and `tools/arcref.py`
> together if anything differs.

## Link

- 115200 baud, 8N1, no flow control
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

## Board → browser: real referee frames (2026 layouts)

These are what the **link robot** would receive: red 3 by default, set in
`CONFIG`. A robot's referee parser should accept them as they are.

| cmd_id | Name | Rate | Data |
|---|---|---|---|
| `0x0001` | game_status | 1 Hz + on stage change | `u8` game_type (bits 0–3) \| game_progress (bits 4–7), `u16` stage_remain_time, `u64` SyncTimeStamp |
| `0x0002` | game_result | at round end | `u8` winner: 0 draw, 1 red, 2 blue |
| `0x0003` | game_robot_HP | ~3 Hz | 8 × `u16` **ally** HP: 1, 2, 3, 4, reserved, 7, outpost, base. Only ally_3 is filled |
| `0x0104` | referee_warning | on penalty + 1 Hz | `u8` level (1 both yellow, 2 yellow, 3 red, 4 forfeit), `u8` offending robot_id (0 for both-yellow/forfeit), `u8` count. Own team only |
| `0x0201` | robot_status | 10 Hz | `u8` robot_id, `u8` level, `u16` current_HP, `u16` maximum_HP, `u16` barrel cooling/s, `u16` barrel heat limit, `u16` chassis power limit, `u8` outputs (bit0 gimbal, bit1 chassis, bit2 shooter) |
| `0x0202` | power_heat_data | 10 Hz | `u16` reserved, `u16` reserved, `u32` reserved, `u16` buffer energy J, `u16` 17 mm barrel heat, `u16` 42 mm barrel heat (14 bytes) |
| `0x0206` | hurt_data | on hit | `u8` armor_id (bits 0–3) \| reason (bits 4–7): 0 projectile, 1 module offline, 5 collision |
| `0x0207` | shoot_data | on shot | `u8` bullet type (1 = 17 mm), `u8` shooter number (1), `u8` launch frequency, `f32` speed m/s (V1.6 layout, unverified for 2026) |

game_progress values: 0 not started, 1 preparation (setup period), 2 15 s
Referee System self-check, 3 5 s countdown, 4 in battle, 5 settlement.
Robot IDs: red Infantry 3, blue Infantry 103.

## Board → browser: console frames

| cmd_id | Name | Rate | Data |
|---|---|---|---|
| `0xF101` | server_state | 10 Hz | 66 bytes, below |
| `0xF102` | server_event | every event, both robots | `u8` robot, `u8` kind, `u8` detail, `u16` HP after |

`0xF101` layout:

| Offset | Field |
|---|---|
| 0 | `u8` stage (game_progress) |
| 1 | `u8` bit0 paused, bits 1–2 first damaged (1 red, 2 blue), bits 3–4 first to fire |
| 2 | `u16` remaining seconds in this stage |
| 4 | `u8` winner, `u8` win reason (1 defeat, 2 more HP, 3 opponent took first damage, 4 more shots, 5 fired first, 6 tie: lighter robot wins, decided by the referee, 7 forfeit) |
| 6 | `u8` link robot, `u8` game_type |
| 8 / 30 | robot 0 / robot 1, 22 bytes each: `u16` hp, max_hp, heat, heat_limit, buffer J, power W, power_limit, projectiles left, shots fired; `u8` yellow cards, `u8` flags (bit0 alive, bit1 red card, bit2 shooter on, bit3 chassis on, bit4 gimbal on, bit5 disconnected, bit6 heat-locked, bit7 speed-locked), `u8` speed lock seconds left (255 = rest of round), `u8` chassis cut time left in 0.1 s |
| 52 | `u16` control frames ok, bad; battle s, cooling/s, 17 mm damage, setup s, speed limit m/s |

Event kinds: 1 hit (detail = armor, +0x80 board button, +0x40 collision, +0x20
42 mm), 2 shot, 3 launcher locked, 4 chassis cut, 5 yellow card (detail =
count), 6 red card (detail 1 = from three yellows), 7 forfeit, 8 kill, 9 revive,
10 disconnect, 11 reconnect, 12 offline HP loss, 13 launcher unlocked,
14 both-teams yellow.

Lock details (kinds 3 and 13): 1 heat, 2 heat over limit + 100, 3 speed 15 s,
4 speed 20 s, 5 speed rest of round, 6 out of projectiles.

## Browser → board: control frames

Robot index: 0 = red, 1 = blue.

| cmd_id | Name | Data |
|---|---|---|
| `0xF001` | GAME | `u8` action: 1 start setup period, 2 skip to referee init, 3 pause (timeout), 4 resume, 5 end round, 6 reset |
| `0xF002` | CONFIG | `u8` game_type, `u8` link robot, `u16` battle s, max HP, heat limit, cooling/s, chassis power limit W, 17 mm damage, setup s, speed limit m/s, projectile allowance (20 bytes). **Only accepted while not started.** |
| `0xF003` | HIT | `u8` robot, `u8` armor 0–3, `u8` kind: 0 17 mm, 1 collision, 2 42 mm |
| `0xF004` | SHOOT | `u8` robot, `u8` frequency, `f32` speed m/s (copied into `0x0207`), `u16` speed in 0.1 m/s (used for the speed-limit check) |
| `0xF005` | PENALTY | `u8` robot, `u8` level: 1 both teams yellow, 2 yellow, 3 red, 4 forfeit |
| `0xF006` | LIFE | `u8` robot, `u8` 0 kill, 1 revive, 2 abnormal disconnection, 3 reconnect |
| `0xF007` | POWER | `u8` robot, `u16` simulated chassis draw W |
| `0xF008` | TIME | `u32` Unix time (sent by the console on connect) |

## Rules model (ARCC 2026 Events Manual V1.6)

The core implements the **1v1** event (section 4), with one Infantry per side.
Defaults are table 4-2: 200 HP, barrel heat limit 80, cooling 12/s, chassis
power 120 W, speed limit 25 m/s, 200 projectiles, 2 min setup, 2 min battle.
The console's 3v3 presets only change these numbers. Victory points, the
capture point, gold coins and respawn are not modelled.

| Rule | Manual | Implemented as |
|---|---|---|
| Round flow | 7.4–7.8 | setup period (pausable for timeouts) → 15 s init (HP reset) → 5 s countdown → battle → settlement |
| Attack damage | 3.3.1.1, table 3-7 | 17 mm 20, 42 mm 200, collision 2. Only in an unpaused battle, and only to an alive, connected robot |
| Barrel heat | 3.3.1.3 | +10 per 17 mm shot; cools cooling/10 every 100 ms. Heat > limit locks the launcher until heat = 0; heat > limit + 100 locks it for the round. No HP loss |
| Projectile speed | 3.3.1.2, table 3-8 | over by < 5 m/s: 15 s lock, < 10: 20 s, ≥ 10: rest of round. Locks don't stack (the longer one wins) |
| Chassis power | 3.3.1.4 | buffer 60 J, checked at 10 Hz. Over the limit drains (P − limit)/10 J per tick; when empty the chassis is cut for 5 s. No HP loss |
| Projectile allowance | 4.1.1 | each shot uses one; at 0 the launcher is off |
| Abnormal disconnection | 3.3.1.5.1 | outputs off, damage not detected, −5 % max HP per second |
| Yellow card | 8.1.2 | −15 % max HP; another within 30 s doubles the previous percentage; never below 1 HP; the third yellow is a red card. Both teams yellow: −5 % to every robot |
| Red card | 8.1.2 | HP → 0 (ejected) |
| Forfeit | 8.1.2 (1v1) | before battle: offender 0 HP, other full; during battle: HP kept. Other side wins |
| Winning | 4.4 | defeat ends the round immediately. At time-out: more HP → the side that did not take the first damage → more shots → fired first → otherwise a tie (the referee decides by weight) |
| Kill / revive | (referee tools) | not in the manual. They are for bench testing |

**Not modelled:** the 2/5 s pilot UI blackout after a yellow card, the 42 mm
immunity rules, armor detection intervals and speed thresholds, Speed Monitor
and Armor Module disconnection, and anything 3v3-specific.

## Board buttons and LEDs

| Item | Function |
|---|---|
| BTN0–3 | 17 mm hit on armor plate 0–3 (front, left, back, right) |
| SW0 | robot the buttons hit: down = red, up = blue |
| LD0 | battle running (blinks while paused) |
| LD1 / LD2 | red / blue alive |
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
