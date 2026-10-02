`timescale 1ns / 1ps
// Referee core: ARCC 2026 1v1 rules (Events Manual V1.6, sections 3.3.1, 4,
// 7 and 8.1) for two robots, 0 = red Infantry (ID 3), 1 = blue (ID 103).
//
//   - Setup period, 15 s Referee System initialization, 5 s countdown, battle,
//     settlement (game_progress 1..5). Pause works in setup and later stages.
//   - Damage: 17 mm hit (cfg, 20), 42 mm hit 200, collision 2. Only alive,
//     connected robots in an unpaused battle take damage.
//   - Barrel heat: +10 per 17 mm shot, cools cooling/10 every 100 ms.
//     heat > limit locks the launcher until heat is 0; heat > limit + 100
//     locks it for the rest of the round. No HP loss.
//   - Projectile speed over the limit by <5 / <10 / >=10 m/s locks the
//     launcher 15 s / 20 s / rest of round. Locks do not stack.
//   - Chassis power over the limit drains the 60 J buffer; once it is empty
//     the chassis is cut for 5 s. No HP loss.
//   - Projectile allowance: each shot uses one; at 0 the launcher is off.
//   - Yellow card: -15 % max HP (doubled for each repeat within 30 s),
//     never below 1 HP; the third yellow is a red card. Both-teams yellow:
//     -5 % to every robot. Red card: HP 0.
//   - Abnormal disconnection: outputs off, no damage detected, -5 % max HP
//     per second.
//   - A robot reaching 0 HP in battle ends the round. At time-out the 1v1
//     winning criteria (4.4) decide; the weight tiebreak is left to the
//     referee (reported as a draw with reason 6).
//
// The JS emulator in web/js/sim.js mirrors this file; web/test checks that
// both produce the same result. Keep them in step.
module arc_ref_core #(
    parameter integer CLK_HZ = 100_000_000
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         cmd_valid,
    input  wire [15:0]  cmd_id,
    input  wire [7:0]   cmd_len,
    input  wire [191:0] cmd_data,

    input  wire [3:0]   btn_hit,      // one-cycle pulse per armor plate
    input  wire         btn_target,   // robot the buttons hit

    output reg          tick_20ms,

    output reg  [2:0]   stage,
    output reg          paused,
    output reg  [15:0]  remain,
    output reg  [1:0]   winner,       // 0 draw / none, 1 red, 2 blue
    output reg  [7:0]   win_reason,
    output reg  [1:0]   first_dmg,    // 0 none, 1 red took first damage, 2 blue
    output reg  [1:0]   first_shot,   // 0 none, 1 red fired first, 2 blue
    output reg  [3:0]   game_type,
    output reg          link_robot,
    output reg  [31:0]  unix_time,

    output reg  [15:0]  cfg_combat_time,
    output reg  [15:0]  cfg_max_hp,
    output reg  [15:0]  cfg_heat_limit,
    output reg  [15:0]  cfg_cooling,
    output reg  [15:0]  cfg_power_limit,
    output reg  [15:0]  cfg_hit_dmg,
    output reg  [15:0]  cfg_setup_time,
    output reg  [15:0]  cfg_speed_limit,
    output reg  [15:0]  cfg_allowance,

    // Per-robot state, packed {robot1, robot0}
    output wire [31:0]  hp_flat,
    output wire [31:0]  heat_flat,       // integer heat
    output wire [31:0]  buffer_flat,     // integer joules
    output wire [31:0]  power_flat,      // watts (simulated draw)
    output wire [31:0]  allowance_flat,
    output wire [31:0]  shots_flat,
    output wire [15:0]  yellow_flat,
    output wire [15:0]  rflags_flat,     // see RF_* below
    output wire [15:0]  lock_s_flat,     // speed lock seconds left, 255 = round
    output wire [15:0]  chassis_ds_flat, // chassis cut, tenths of a second left

    // Two event slots per cycle, packed {B, A}; arc_frame_gen queues A first.
    output reg  [1:0]   ev_valid,
    output reg  [1:0]   ev_robot,
    output reg  [15:0]  ev_kind,
    output reg  [15:0]  ev_detail,
    output reg  [31:0]  ev_hp,

    output reg          hurt_valid,    // link robot only (0x0206)
    output reg  [7:0]   hurt_byte,
    output reg          shot_valid,    // link robot only (0x0207)
    output reg  [7:0]   shot_freq,
    output reg  [31:0]  shot_speed,
    output reg          warn_valid,    // link team only (0x0104)
    output reg  [7:0]   warn_level,
    output reg  [7:0]   warn_id,
    output reg  [7:0]   warn_count,
    output reg          result_valid,  // 0x0002
    output reg          stage_valid    // stage/pause changed, push 0x0001 now
);
    // game_progress values (0x0001)
    localparam [2:0] ST_IDLE   = 3'd0,
                     ST_PREP   = 3'd1,
                     ST_CHECK  = 3'd2,
                     ST_COUNT  = 3'd3,
                     ST_COMBAT = 3'd4,
                     ST_RESULT = 3'd5;

    localparam [15:0] CHECK_S = 16'd15;
    localparam [15:0] COUNT_S = 16'd5;
    localparam [15:0] BUFFER_FULL_X10 = 16'd600;  // 60 J
    localparam [15:0] LOCK_ROUND = 16'hFFFF;
    localparam [15:0] YELLOW_WINDOW = 16'd300;    // 30 s in 100 ms ticks
    localparam [7:0]  CHASSIS_CUT = 8'd50;        // 5 s in 100 ms ticks

    // Control command IDs
    localparam [15:0] C_GAME    = 16'hF001,
                      C_CONFIG  = 16'hF002,
                      C_HIT     = 16'hF003,
                      C_SHOOT   = 16'hF004,
                      C_PENALTY = 16'hF005,
                      C_LIFE    = 16'hF006,
                      C_POWER   = 16'hF007,
                      C_TIME    = 16'hF008;

    // Event kinds (0xF102)
    localparam [7:0] EV_HIT = 8'd1, EV_SHOT = 8'd2, EV_LOCK = 8'd3,
                     EV_CHASSIS = 8'd4, EV_YELLOW = 8'd5, EV_RED = 8'd6,
                     EV_FORFEIT = 8'd7, EV_KILL = 8'd8, EV_REVIVE = 8'd9,
                     EV_DISCONNECT = 8'd10, EV_RECONNECT = 8'd11,
                     EV_OFFLINE_HP = 8'd12, EV_UNLOCK = 8'd13,
                     EV_YELLOW_BOTH = 8'd14;

    // EV_LOCK / EV_UNLOCK detail
    localparam [7:0] LK_HEAT = 8'd1, LK_HEAT_ROUND = 8'd2, LK_SPEED15 = 8'd3,
                     LK_SPEED20 = 8'd4, LK_SPEED_ROUND = 8'd5, LK_AMMO = 8'd6;

    // win_reason
    localparam [7:0] WR_NONE = 8'd0, WR_DEFEAT = 8'd1, WR_HP = 8'd2,
                     WR_FIRST_DMG = 8'd3, WR_SHOTS = 8'd4, WR_FIRST_SHOT = 8'd5,
                     WR_TIE = 8'd6, WR_FORFEIT = 8'd7;

    // 0x0206 HP_deduction_reason
    localparam [3:0] RS_ARMOR = 4'd0, RS_COLLISION = 4'd5;

    localparam integer TICK_DIV = CLK_HZ / 50;

    reg [15:0] hp      [0:1];
    reg [15:0] heat10  [0:1];   // heat x10
    reg [15:0] buf10   [0:1];   // buffer energy x0.1 J
    reg [15:0] power   [0:1];
    reg [15:0] ammo    [0:1];   // projectile allowance
    reg [15:0] shots   [0:1];
    reg [7:0]  yellow  [0:1];
    reg [7:0]  yel_pct [0:1];   // percentage of the last yellow card
    reg [15:0] yel_win [0:1];   // 100 ms ticks left in the repeat window
    reg        red     [0:1];
    reg [1:0]  heat_lk [0:1];   // 0 none, 1 until heat 0, 2 rest of round
    reg [15:0] spd_lk  [0:1];   // 100 ms ticks left, LOCK_ROUND = round
    reg [7:0]  ch_off  [0:1];   // 100 ms ticks of chassis cut left
    reg        disc    [0:1];
    reg [3:0]  disc_t  [0:1];
    reg [7:0]  both_yellow;

    reg [31:0] tdiv;
    reg [2:0]  t5;     // 20 ms ticks within 100 ms
    reg [3:0]  t10;    // 100 ms ticks within 1 s (wall clock)
    reg [3:0]  sub;    // 100 ms ticks within 1 s (match timer)
    reg [2:0]  step;   // 100 ms housekeeping, one job per cycle

    reg         cmd_pend;
    reg [15:0]  c_id;
    reg [7:0]   c_len;
    reg [191:0] c_data;
    reg [3:0]   btn_pend;
    reg         btn_r;

    wire in_combat = (stage == ST_COMBAT) && !paused;
    wire [15:0] heat_limit10 = (cfg_heat_limit << 3) + (cfg_heat_limit << 1);
    wire [15:0] heat_round10 = heat_limit10 + 16'd1000;           // (limit + 100) x10

    // x / 10 for x < 65536 (exact), used to report heat and buffer
    function [15:0] div10;
        input [15:0] x;
        reg [31:0] p;
        begin
            p = x * 32'd52429;
            div10 = {3'b000, p[31:19]};
        end
    endfunction

    // round(x * p / 100) for x < 65536, p < 256
    function [15:0] pct_of;
        input [15:0] x;
        input [7:0]  p;
        reg [23:0] n;
        reg [47:0] q;
        begin
            n = x * p + 24'd50;
            q = n * 48'd1342178;               // 2^27 / 100, exact for n < 1.8M
            pct_of = q[42:27];
        end
    endfunction

    function [7:0] robot_id;
        input r;
        robot_id = r ? 8'd103 : 8'd3;
    endfunction

    function alive;
        input r;
        alive = hp[r] != 16'd0;
    endfunction

    function shooter_on;
        input r;
        shooter_on = alive(r) && !disc[r] && heat_lk[r] == 2'd0
                     && spd_lk[r] == 16'd0 && ammo[r] != 16'd0;
    endfunction

    function [7:0] lock_s;
        input [15:0] t;
        reg [15:0] s;
        begin
            s = div10(t + 16'd9);
            lock_s = (t == LOCK_ROUND) ? 8'd255 : (s > 16'd254 ? 8'd254 : s[7:0]);
        end
    endfunction

    // 1v1 winning criteria at time-out (Events Manual 4.4), {winner, reason}
    function [9:0] judge;
        input dummy;
        begin
            if (hp[0] != hp[1])
                judge = {(hp[0] > hp[1]) ? 2'd1 : 2'd2, WR_HP};
            else if (hp[0] != cfg_max_hp && first_dmg != 2'd0)
                judge = {(first_dmg == 2'd1) ? 2'd2 : 2'd1, WR_FIRST_DMG};
            else if (shots[0] != shots[1])
                judge = {(shots[0] > shots[1]) ? 2'd1 : 2'd2, WR_SHOTS};
            else if (first_shot != 2'd0)
                judge = {first_shot, WR_FIRST_SHOT};
            else
                judge = {2'd0, WR_TIE};
        end
    endfunction

    assign hp_flat         = {hp[1], hp[0]};
    assign heat_flat       = {div10(heat10[1]), div10(heat10[0])};
    assign buffer_flat     = {div10(buf10[1]), div10(buf10[0])};
    assign power_flat      = {power[1], power[0]};
    assign allowance_flat  = {ammo[1], ammo[0]};
    assign shots_flat      = {shots[1], shots[0]};
    assign yellow_flat     = {yellow[1], yellow[0]};
    // Output flags per robot. Written out explicitly (not via functions that
    // read the arrays) so every simulator re-evaluates them.
    wire [1:0] alive_w   = {hp[1] != 16'd0, hp[0] != 16'd0};
    wire [1:0] gimbal_w  = alive_w & ~{disc[1], disc[0]};
    wire [1:0] chassis_w = gimbal_w & {ch_off[1] == 8'd0, ch_off[0] == 8'd0};
    wire [1:0] hlk_w     = {heat_lk[1] != 2'd0, heat_lk[0] != 2'd0};
    wire [1:0] slk_w     = {spd_lk[1] != 16'd0, spd_lk[0] != 16'd0};
    wire [1:0] shooter_w = gimbal_w & ~hlk_w & ~slk_w & {ammo[1] != 16'd0, ammo[0] != 16'd0};
    assign rflags_flat = {slk_w[1], hlk_w[1], disc[1], gimbal_w[1], chassis_w[1], shooter_w[1], red[1], alive_w[1],
                          slk_w[0], hlk_w[0], disc[0], gimbal_w[0], chassis_w[0], shooter_w[0], red[0], alive_w[0]};
    assign lock_s_flat     = {lock_s(spd_lk[1]), lock_s(spd_lk[0])};
    assign chassis_ds_flat = {ch_off[1], ch_off[0]};

    task emit_ev;
        input        slot;
        input        r;
        input [7:0]  kind;
        input [7:0]  detail;
        input [15:0] hp_after;
        begin
            ev_valid[slot]          <= 1'b1;
            ev_robot[slot]          <= r;
            ev_kind[8*slot +: 8]    <= kind;
            ev_detail[8*slot +: 8]  <= detail;
            ev_hp[16*slot +: 16]    <= hp_after;
        end
    endtask

    task finish;
        input [1:0] w;
        input [7:0] why;
        begin
            stage        <= ST_RESULT;
            remain       <= 16'd0;
            paused       <= 1'b0;
            winner       <= w;
            win_reason   <= why;
            result_valid <= 1'b1;
            stage_valid  <= 1'b1;
        end
    endtask

    // Set HP after a loss; a robot defeated in battle ends the round.
    task set_hp;
        input        r;
        input [15:0] nh;
        begin
            hp[r] <= nh;
            if (in_combat && first_dmg == 2'd0) first_dmg <= r ? 2'd2 : 2'd1;
            if (stage == ST_COMBAT && nh == 16'd0) finish(r ? 2'd1 : 2'd2, WR_DEFEAT);
        end
    endtask

    task warn;
        input       r;
        input [7:0] level;
        input [7:0] id;
        input [7:0] count;
        begin
            if (r == link_robot) begin
                warn_valid <= 1'b1;
                warn_level <= level;
                warn_id    <= id;
                warn_count <= count;
            end
        end
    endtask

    task reset_robots;
        integer i;
        begin
            for (i = 0; i < 2; i = i + 1) begin
                hp[i] <= cfg_max_hp;
                heat10[i] <= 16'd0;
                buf10[i] <= BUFFER_FULL_X10;
                ammo[i] <= cfg_allowance;
                shots[i] <= 16'd0;
                yellow[i] <= 8'd0;
                yel_pct[i] <= 8'd0;
                yel_win[i] <= 16'd0;
                red[i] <= 1'b0;
                heat_lk[i] <= 2'd0;
                spd_lk[i] <= 16'd0;
                ch_off[i] <= 8'd0;
                disc[i] <= 1'b0;
                disc_t[i] <= 4'd0;
            end
            both_yellow <= 8'd0;
            first_dmg <= 2'd0;
            first_shot <= 2'd0;
            winner <= 2'd0;
            win_reason <= WR_NONE;
        end
    endtask

    // Armor hit: kind 0 = 17 mm, 1 = collision, 2 = 42 mm.
    task hit;
        input       r;
        input [3:0] armor;
        input [1:0] kind;
        input       button;
        reg [15:0]  dmg;
        reg [15:0]  nh;
        begin
            if (in_combat && alive(r) && !disc[r]) begin
                dmg = (kind == 2'd1) ? 16'd2 : (kind == 2'd2) ? 16'd200 : cfg_hit_dmg;
                nh  = (hp[r] > dmg) ? hp[r] - dmg : 16'd0;
                set_hp(r, nh);
                emit_ev(1'b0, r, EV_HIT, {button, kind == 2'd1, kind == 2'd2, 1'b0, armor}, nh);
                if (r == link_robot) begin
                    hurt_valid <= 1'b1;
                    hurt_byte  <= {(kind == 2'd1) ? RS_COLLISION : RS_ARMOR, armor};
                end
            end
        end
    endtask

    // Penalty HP loss: never below 1 HP (8.1.2).
    function [15:0] penalty_hp;
        input [15:0] h;
        input [15:0] ded;
        penalty_hp = (h == 16'd0) ? 16'd0 : (h <= ded) ? 16'd1 : h - ded;
    endfunction

    task yellow_card;
        input r;
        reg [7:0]  cnt;
        reg [8:0]  pct;
        reg [15:0] nh;
        begin
            cnt = yellow[r] + 8'd1;
            pct = (yel_win[r] != 16'd0) ? {yel_pct[r], 1'b0} : 9'd15;
            if (pct > 9'd200) pct = 9'd200;
            yellow[r]  <= cnt;
            yel_pct[r] <= pct[7:0];
            yel_win[r] <= YELLOW_WINDOW;
            warn(r, 8'd2, robot_id(r), cnt);
            if (cnt >= 8'd3) begin               // third yellow: red card
                red[r] <= 1'b1;
                set_hp(r, 16'd0);
                emit_ev(1'b0, r, EV_YELLOW, cnt, 16'd0);
                emit_ev(1'b1, r, EV_RED, 8'd1, 16'd0);
            end else begin
                nh = penalty_hp(hp[r], pct_of(cfg_max_hp, pct[7:0]));
                if (nh != hp[r]) set_hp(r, nh);
                emit_ev(1'b0, r, EV_YELLOW, cnt, nh);
            end
        end
    endtask

    task heat_step;
        input r;
        reg [15:0] h;
        begin
            if (!paused) begin
                h = heat10[r];
                if (in_combat && alive(r) && heat_lk[r] != 2'd2 && h > heat_round10) begin
                    heat_lk[r] <= 2'd2;
                    emit_ev(1'b0, r, EV_LOCK, LK_HEAT_ROUND, hp[r]);
                end else if (in_combat && alive(r) && heat_lk[r] == 2'd0 && h > heat_limit10) begin
                    heat_lk[r] <= 2'd1;
                    emit_ev(1'b0, r, EV_LOCK, LK_HEAT, hp[r]);
                end else if (heat_lk[r] == 2'd1 && h <= cfg_cooling) begin
                    heat_lk[r] <= 2'd0;
                    emit_ev(1'b0, r, EV_UNLOCK, LK_HEAT, hp[r]);
                end
                heat10[r] <= (h > cfg_cooling) ? h - cfg_cooling : 16'd0;
            end
        end
    endtask

    task power_step;
        input r;
        reg [15:0] d;
        reg [15:0] p;
        reg [16:0] refill;
        begin
            if (in_combat && alive(r) && !disc[r]) begin
                p = (ch_off[r] != 8'd0) ? 16'd0 : power[r];    // cut chassis draws nothing
                if (ch_off[r] != 8'd0) ch_off[r] <= ch_off[r] - 8'd1;
                if (p > cfg_power_limit) begin
                    d = p - cfg_power_limit;
                    if (buf10[r] > d) begin
                        buf10[r] <= buf10[r] - d;
                    end else begin
                        buf10[r] <= 16'd0;
                        ch_off[r] <= CHASSIS_CUT;
                        emit_ev(1'b0, r, EV_CHASSIS, 8'd0, hp[r]);
                    end
                end else begin
                    refill = buf10[r] + (cfg_power_limit - p);
                    buf10[r] <= (refill > BUFFER_FULL_X10) ? BUFFER_FULL_X10 : refill[15:0];
                end
            end else if (!paused) begin
                buf10[r] <= BUFFER_FULL_X10;
                ch_off[r] <= 8'd0;
            end
        end
    endtask

    // Speed lock countdown, yellow-card window, offline HP drain.
    task timer_step;
        input r;
        reg [15:0] nh;
        begin
            if (in_combat) begin
                if (yel_win[r] != 16'd0) yel_win[r] <= yel_win[r] - 16'd1;
                if (spd_lk[r] == 16'd1) begin
                    spd_lk[r] <= 16'd0;
                    emit_ev(1'b0, r, EV_UNLOCK, LK_SPEED15, hp[r]);
                end else if (spd_lk[r] != 16'd0 && spd_lk[r] != LOCK_ROUND) begin
                    spd_lk[r] <= spd_lk[r] - 16'd1;
                end
                if (disc[r] && alive(r)) begin
                    if (disc_t[r] == 4'd9) begin
                        disc_t[r] <= 4'd0;
                        nh = pct_of(cfg_max_hp, 8'd5);
                        nh = (hp[r] > nh) ? hp[r] - nh : 16'd0;
                        set_hp(r, nh);
                        emit_ev(1'b0, r, EV_OFFLINE_HP, 8'd0, nh);
                    end else begin
                        disc_t[r] <= disc_t[r] + 4'd1;
                    end
                end
            end
        end
    endtask

    task run_cmd;
        reg        r;
        reg [7:0]  a;
        reg [16:0] h;
        reg [15:0] sp;
        reg [15:0] lim10;
        reg [15:0] lk;
        reg [7:0]  lkd;
        reg [15:0] nh0, nh1;
        begin
            r = c_data[0];
            a = c_data[15:8];
            case (c_id)
                C_GAME: case (c_data[7:0])
                    8'd1: if (stage == ST_IDLE) begin           // setup period
                        stage <= ST_PREP; remain <= cfg_setup_time; sub <= 4'd0;
                        paused <= 1'b0; stage_valid <= 1'b1;
                    end
                    8'd2: if (stage == ST_IDLE || stage == ST_PREP) begin  // skip to init
                        stage <= ST_CHECK; remain <= CHECK_S; sub <= 4'd0;
                        paused <= 1'b0;
                        reset_robots();
                        stage_valid <= 1'b1;
                    end
                    8'd3: if (stage >= ST_PREP && stage <= ST_COMBAT && !paused) begin
                        paused <= 1'b1; stage_valid <= 1'b1;
                    end
                    8'd4: if (paused) begin
                        paused <= 1'b0; stage_valid <= 1'b1;
                    end
                    8'd5: if (stage >= ST_PREP && stage <= ST_COMBAT)
                        finish(judge(1'b0) >> 8, judge(1'b0));
                    8'd6: begin                                   // reset
                        stage <= ST_IDLE; remain <= 16'd0; paused <= 1'b0;
                        reset_robots();
                        power[0] <= 16'd0; power[1] <= 16'd0;
                        warn_valid <= 1'b1; warn_level <= 8'd0; warn_id <= 8'd0; warn_count <= 8'd0;
                        stage_valid <= 1'b1;
                    end
                    default: ;
                endcase
                C_CONFIG: if (stage == ST_IDLE && c_len >= 8'd20) begin
                    game_type       <= c_data[3:0];
                    link_robot      <= c_data[8];
                    cfg_combat_time <= c_data[31:16];
                    cfg_max_hp      <= c_data[47:32];
                    cfg_heat_limit  <= c_data[63:48];
                    cfg_cooling     <= c_data[79:64];
                    cfg_power_limit <= c_data[95:80];
                    cfg_hit_dmg     <= c_data[111:96];
                    cfg_setup_time  <= c_data[127:112];
                    cfg_speed_limit <= c_data[143:128];
                    cfg_allowance   <= c_data[159:144];
                    hp[0] <= c_data[47:32];   hp[1] <= c_data[47:32];
                    ammo[0] <= c_data[159:144]; ammo[1] <= c_data[159:144];
                    stage_valid <= 1'b1;
                end
                C_HIT: hit(r, a[3:0], (c_len >= 8'd3) ? c_data[17:16] : 2'd0, 1'b0);
                C_SHOOT: if (in_combat && shooter_on(r)) begin
                    h = heat10[r] + 17'd100;               // 17 mm: +10 heat
                    heat10[r] <= h[16] ? 16'hFFFF : h[15:0];
                    ammo[r]  <= ammo[r] - 16'd1;
                    shots[r] <= shots[r] + 16'd1;
                    if (first_shot == 2'd0) first_shot <= r ? 2'd2 : 2'd1;
                    emit_ev(1'b0, r, EV_SHOT, a, hp[r]);
                    // Speed check uses the u16 0.1 m/s field when present.
                    sp = (c_len >= 8'd8) ? c_data[63:48] : 16'd0;
                    lim10 = (cfg_speed_limit << 3) + (cfg_speed_limit << 1);
                    if (sp > lim10) begin
                        if (sp - lim10 < 16'd50)       begin lk = 16'd150;    lkd = LK_SPEED15; end
                        else if (sp - lim10 < 16'd100) begin lk = 16'd200;    lkd = LK_SPEED20; end
                        else                           begin lk = LOCK_ROUND; lkd = LK_SPEED_ROUND; end
                        if (spd_lk[r] != LOCK_ROUND && lk > spd_lk[r]) spd_lk[r] <= lk;
                        emit_ev(1'b1, r, EV_LOCK, lkd, hp[r]);
                    end else if (ammo[r] == 16'd1) begin
                        emit_ev(1'b1, r, EV_LOCK, LK_AMMO, hp[r]);
                    end
                    if (r == link_robot) begin
                        shot_valid <= 1'b1;
                        shot_freq  <= a;
                        shot_speed <= c_data[47:16];
                    end
                end
                C_PENALTY: case (a)
                    8'd1: begin                                   // both teams yellow
                        nh0 = penalty_hp(hp[0], pct_of(cfg_max_hp, 8'd5));
                        nh1 = penalty_hp(hp[1], pct_of(cfg_max_hp, 8'd5));
                        hp[0] <= nh0;
                        hp[1] <= nh1;
                        both_yellow <= both_yellow + 8'd1;
                        emit_ev(1'b0, 1'b0, EV_YELLOW_BOTH, both_yellow + 8'd1, nh0);
                        emit_ev(1'b1, 1'b1, EV_YELLOW_BOTH, both_yellow + 8'd1, nh1);
                        warn(link_robot, 8'd1, 8'd0, both_yellow + 8'd1);
                    end
                    8'd2: yellow_card(r);
                    8'd3: begin                                   // red card
                        red[r] <= 1'b1;
                        set_hp(r, 16'd0);
                        emit_ev(1'b0, r, EV_RED, 8'd0, 16'd0);
                        warn(r, 8'd3, robot_id(r), 8'd1);
                    end
                    8'd4: if (stage >= ST_PREP && stage <= ST_COMBAT) begin  // forfeit
                        if (stage != ST_COMBAT) begin             // before battle: 0 vs full
                            hp[r] <= 16'd0;
                            hp[~r] <= cfg_max_hp;
                        end
                        emit_ev(1'b0, r, EV_FORFEIT, 8'd0, (stage != ST_COMBAT) ? 16'd0 : hp[r]);
                        warn(r, 8'd4, 8'd0, 8'd1);
                        finish(r ? 2'd1 : 2'd2, WR_FORFEIT);
                    end
                    default: ;
                endcase
                C_LIFE: case (a)
                    8'd0: begin                                   // kill
                        set_hp(r, 16'd0);
                        emit_ev(1'b0, r, EV_KILL, 8'd0, 16'd0);
                    end
                    8'd1: begin                                   // revive (referee tool)
                        hp[r] <= cfg_max_hp;
                        heat10[r] <= 16'd0;
                        red[r] <= 1'b0;
                        heat_lk[r] <= 2'd0;
                        spd_lk[r] <= 16'd0;
                        disc[r] <= 1'b0;
                        emit_ev(1'b0, r, EV_REVIVE, 8'd0, cfg_max_hp);
                    end
                    8'd2: if (!disc[r]) begin                     // abnormal disconnection
                        disc[r] <= 1'b1;
                        disc_t[r] <= 4'd0;
                        emit_ev(1'b0, r, EV_DISCONNECT, 8'd0, hp[r]);
                    end
                    8'd3: if (disc[r]) begin                      // reconnect
                        disc[r] <= 1'b0;
                        emit_ev(1'b0, r, EV_RECONNECT, 8'd0, hp[r]);
                    end
                    default: ;
                endcase
                C_POWER: power[r] <= c_data[23:8];
                C_TIME:  unix_time <= c_data[31:0];
                default: ;
            endcase
        end
    endtask

    reg [3:0] bclr;
    integer i;

    always @(posedge clk) begin
        bclr          = 4'd0;
        tick_20ms    <= 1'b0;
        ev_valid     <= 2'b00;
        hurt_valid   <= 1'b0;
        shot_valid   <= 1'b0;
        warn_valid   <= 1'b0;
        result_valid <= 1'b0;
        stage_valid  <= 1'b0;

        if (rst) begin
            tdiv <= 32'd0; t5 <= 3'd0; t10 <= 4'd0; sub <= 4'd0; step <= 3'd0;
            stage <= ST_IDLE; paused <= 1'b0; remain <= 16'd0;
            game_type <= 4'd5;             // RMUL 1v1
            link_robot <= 1'b0;
            unix_time <= 32'd0;
            // ARCC 2026 1v1 Infantry (Events Manual table 4-2)
            cfg_combat_time <= 16'd120;
            cfg_max_hp      <= 16'd200;
            cfg_heat_limit  <= 16'd80;
            cfg_cooling     <= 16'd12;
            cfg_power_limit <= 16'd120;
            cfg_hit_dmg     <= 16'd20;
            cfg_setup_time  <= 16'd120;
            cfg_speed_limit <= 16'd25;
            cfg_allowance   <= 16'd200;
            for (i = 0; i < 2; i = i + 1) begin
                hp[i] <= 16'd200; heat10[i] <= 16'd0; buf10[i] <= BUFFER_FULL_X10;
                power[i] <= 16'd0; ammo[i] <= 16'd200; shots[i] <= 16'd0;
                yellow[i] <= 8'd0; yel_pct[i] <= 8'd0; yel_win[i] <= 16'd0;
                red[i] <= 1'b0; heat_lk[i] <= 2'd0; spd_lk[i] <= 16'd0;
                ch_off[i] <= 8'd0; disc[i] <= 1'b0; disc_t[i] <= 4'd0;
            end
            both_yellow <= 8'd0; first_dmg <= 2'd0; first_shot <= 2'd0;
            winner <= 2'd0; win_reason <= WR_NONE;
            cmd_pend <= 1'b0; btn_pend <= 4'd0; btn_r <= 1'b0;
            ev_robot <= 2'd0; ev_kind <= 16'd0; ev_detail <= 16'd0; ev_hp <= 32'd0;
            hurt_byte <= 8'd0; shot_freq <= 8'd0; shot_speed <= 32'd0;
            warn_level <= 8'd0; warn_id <= 8'd0; warn_count <= 8'd0;
        end else begin
            // 50 Hz base tick
            if (tdiv == TICK_DIV - 1) begin
                tdiv <= 32'd0;
                tick_20ms <= 1'b1;
                if (t5 == 3'd4) begin
                    t5 <= 3'd0;
                    step <= 3'd1;        // start 100 ms housekeeping
                    if (t10 == 4'd9) begin
                        t10 <= 4'd0;
                        unix_time <= unix_time + 32'd1;
                    end else begin
                        t10 <= t10 + 4'd1;
                    end
                end else begin
                    t5 <= t5 + 3'd1;
                end
            end else begin
                tdiv <= tdiv + 32'd1;
            end

            // One job per cycle, so at most two event pulses per cycle.
            if (step != 3'd0) begin
                case (step)
                    3'd1: if (!paused && stage >= ST_PREP && stage <= ST_COMBAT) begin
                        if (sub == 4'd9) begin
                            sub <= 4'd0;
                            if (remain > 16'd1) begin
                                remain <= remain - 16'd1;
                            end else begin
                                case (stage)
                                    ST_PREP: begin      // init period resets HP
                                        stage <= ST_CHECK; remain <= CHECK_S; stage_valid <= 1'b1;
                                        reset_robots();
                                    end
                                    ST_CHECK: begin
                                        stage <= ST_COUNT; remain <= COUNT_S; stage_valid <= 1'b1;
                                    end
                                    ST_COUNT: begin
                                        stage <= ST_COMBAT; remain <= cfg_combat_time; stage_valid <= 1'b1;
                                    end
                                    default:
                                        finish(judge(1'b0) >> 8, judge(1'b0));
                                endcase
                            end
                        end else begin
                            sub <= sub + 4'd1;
                        end
                    end
                    3'd2: heat_step(1'b0);
                    3'd3: power_step(1'b0);
                    3'd4: timer_step(1'b0);
                    3'd5: heat_step(1'b1);
                    3'd6: power_step(1'b1);
                    3'd7: timer_step(1'b1);
                    default: ;
                endcase
                step <= (step == 3'd7) ? 3'd0 : step + 3'd1;
            end else if (cmd_pend) begin
                cmd_pend <= 1'b0;
                run_cmd();
            end else if (btn_pend != 4'd0) begin
                if      (btn_pend[0]) begin bclr = 4'b0001; hit(btn_r, 4'd0, 2'd0, 1'b1); end
                else if (btn_pend[1]) begin bclr = 4'b0010; hit(btn_r, 4'd1, 2'd0, 1'b1); end
                else if (btn_pend[2]) begin bclr = 4'b0100; hit(btn_r, 4'd2, 2'd0, 1'b1); end
                else                  begin bclr = 4'b1000; hit(btn_r, 4'd3, 2'd0, 1'b1); end
            end

            // Latch new inputs last so they win over the clears above.
            if (cmd_valid) begin
                cmd_pend <= 1'b1;
                c_id     <= cmd_id;
                c_len    <= cmd_len;
                c_data   <= cmd_data;
            end
            btn_pend <= (btn_pend & ~bclr) | btn_hit;
            if (btn_hit != 4'd0) btn_r <= btn_target;
        end
    end
endmodule
