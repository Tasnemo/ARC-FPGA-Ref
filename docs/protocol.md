# Referee link protocol

The board and the browser use the RoboMaster referee serial format, which ARC
(formerly RoboMaster North America) keeps. Real referee frames carry their real
`cmd_id`. Our own control and console frames use `0xF0xx`/`0xF1xx`, which the
real protocol does not use.

> **Verify before relying on it:** the field layouts below follow the RoboMaster
> *Referee System Serial Port Protocol Appendix* (V1.6.x). Check the IDs and
> layouts against the protocol document ARC publishes for your season, and
> update `hw/rtl/arc_frame_gen.v`, `web/js/protocol.js` and `tools/arcref.py`
> together if anything differs.

## Link

- 115200 baud, 8N1, no flow control (the same as the real referee UART)
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
- The board accepts control frames with at most 16 data bytes. Bad frames
  increment the `rx_err` counter in `0xF101`.

## Board → browser: real referee frames

These are generated for the **link robot**, the robot a real referee module would
be plugged into: red 3 by default, set in `CONFIG`. A robot's existing referee
parser should accept them as they are.

| cmd_id | Name | Rate | Data |
|---|---|---|---|
| `0x0001` | game_status | 1 Hz + on stage change | `u8` game_type (bits 0–3) \| game_progress (bits 4–7), `u16` stage_remain_time, `u64` SyncTimeStamp |
| `0x0002` | game_result | at match end | `u8` winner: 0 draw, 1 red, 2 blue |
| `0x0003` | game_robot_HP | ~3 Hz | 16 × `u16`: red 1,2,3,4,5,7, outpost, base, then blue the same. Only red_3 (offset 4) and blue_3 (offset 20) are filled |
| `0x0104` | referee_warning | on penalty to link robot | `u8` level (2 yellow, 3 red, 4 forfeit), `u8` offending robot_id, `u8` count |
| `0x0201` | robot_status | 10 Hz | `u8` robot_id, `u8` level, `u16` current_HP, `u16` maximum_HP, `u16` barrel cooling, `u16` barrel heat limit, `u16` chassis power limit, `u8` power outputs (bit0 gimbal, bit1 chassis, bit2 shooter) |
| `0x0202` | power_heat_data | 50 Hz | `u16` voltage mV (24000), `u16` current mA, `f32` chassis power W, `u16` buffer energy J, `u16` 17 mm barrel 1 heat, `u16` barrel 2 heat, `u16` 42 mm heat |
| `0x0206` | hurt_data | on HP loss | `u8` armor_id (bits 0–3) \| reason (bits 4–7): 0 armor hit, 3 barrel heat, 4 chassis power |
| `0x0207` | shoot_data | on shot | `u8` bullet type (1 = 17 mm), `u8` shooter number (1), `u8` launch frequency, `f32` speed m/s |

game_progress values: 0 not started, 1 preparation, 2 15 s self-check,
3 5 s countdown, 4 in combat, 5 settlement. Robot IDs: red standard = 3,
blue standard = 103.

## Board → browser: console frames

| cmd_id | Name | Rate | Data |
|---|---|---|---|
| `0xF101` | server_state | 10 Hz | see below (49 bytes) |
| `0xF102` | server_event | every event, both robots | `u8` robot, `u8` kind, `u8` detail, `u16` HP after |

`0xF101` layout:

| Offset | Field |
|---|---|
| 0 | `u8` stage (game_progress) |
| 1 | `u8` flags: bit0 paused |
| 2 | `u16` remaining seconds |
| 4 | `u8` winner |
| 5 | `u8` link robot (0 red, 1 blue) |
| 6 | `u8` game_type |
| 7 / 23 | robot 0 / robot 1, 16 bytes each: `u16` hp, max_hp, heat, heat_limit, buffer (J), power (W), power_limit, `u8` yellow cards, `u8` flags (bit0 alive, bit1 red card) |
| 39 | `u16` control frames accepted |
| 41 | `u16` control frames rejected |
| 43 | `u16` combat time (s) |
| 45 | `u16` cooling per second |
| 47 | `u16` damage per hit |

Event kinds: 1 hit (detail = armor; bit 7 set if it came from a board button),
2 shot (detail = frequency), 3 overheat, 4 overpower, 5 yellow card
(detail = count), 6 red card, 7 forfeit, 8 kill, 9 revive.

## Browser → board: control frames

Robot index: 0 = red, 1 = blue.

| cmd_id | Name | Data |
|---|---|---|
| `0xF001` | GAME | `u8` action: 1 preparation, 2 start (self-check → countdown → combat run automatically), 3 pause, 4 resume, 5 end now, 6 reset |
| `0xF002` | CONFIG | `u8` game_type, `u8` link robot, `u16` combat s, `u16` max HP, `u16` heat limit, `u16` cooling/s, `u16` chassis power limit W, `u16` damage per hit. **Only accepted while not started.** |
| `0xF003` | HIT | `u8` robot, `u8` armor 0–3 |
| `0xF004` | SHOOT | `u8` robot, `u8` frequency, `f32` speed m/s |
| `0xF005` | PENALTY | `u8` robot, `u8` level: 2 yellow, 3 red (robot destroyed), 4 forfeit (other side wins) |
| `0xF006` | LIFE | `u8` robot, `u8` 0 kill / 1 revive (full HP, heat cleared) |
| `0xF007` | POWER | `u8` robot, `u16` simulated chassis draw W |
| `0xF008` | TIME | `u32` Unix time (sent by the console on connect) |

## Rules model (placeholders)

These rules are simple stand-ins. Replace them with the real rules from the
ARC rules manual for your season. They live in `arc_ref_core.v`, with a JS
copy in `web/js/sim.js`. `web/test` checks that the two give the same result.

- Hits, shots and power limits only count during combat while not paused, and
  only for a robot that is still alive.
- Hit: HP −= damage per hit (default 10).
- Shot: +10 barrel heat. Every 100 ms the barrel cools by cooling/10. While
  heat > limit, the robot loses `floor((heat − limit) × 10 / 64) + 1` HP every
  100 ms.
- Chassis: every 100 ms, buffer energy (60 J max) drops by (power − limit) / 10 J.
  Once it is empty, the robot loses `floor((power − limit) / 4) + 1` HP every
  100 ms. Under the limit, the buffer refills by (limit − power) / 10 J per 100 ms.
- Timer end or END: the robot with more HP wins; equal HP is a draw.
- Defaults: 180 s combat, 200 HP, heat limit 100, cooling 20/s, 60 W, 10 damage.

## Board buttons and LEDs

| Item | Function |
|---|---|
| BTN0–3 | armor hit on plate 0–3 (front, left, back, right) |
| SW0 | robot the buttons hit: down = red, up = blue |
| LD0 | combat (blinks while paused) |
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
