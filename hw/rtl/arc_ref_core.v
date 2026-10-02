`timescale 1ns / 1ps
// Referee core for the ARCC 2026 1v1 and 3v3 events (Events Manual V1.6).
//
// Six robot slots: 0 red Hero (ID 1), 1 red Infantry (3), 2 red Sentry (7),
// 3..5 the same for blue (101, 103, 107). The browser sets each slot's stats
// with ROBOT_CONFIG (presets live in the UI); 1v1 fields slots 1 and 4.
//
// Both modes:
//   - setup period (pausable), 15 s init (HP reset), 5 s countdown, battle,
//     settlement (game_progress 1..5)
//   - damage: 17 mm 20, 42 mm 200, collision 2, only in an unpaused battle
//     to an alive, connected robot
//   - barrel heat: +10 per 17 mm / +100 per 42 mm shot, cools cooling/10 per
//     100 ms; over the limit locks the launcher until heat is 0, over
//     limit + 100 (17 mm) / + 200 (42 mm) locks it for the round
//   - speed over the limit locks the launcher 15 s / 20 s / rest of round
//   - an empty 60 J buffer cuts the chassis for 5 s
//   - projectile allowance; yellow card -15 % max HP (doubling within 30 s,
//     never below 1 HP, third is red); both-teams yellow -5 %; red card;
//     abnormal disconnection -5 % per second
// 1v1 only: a defeat ends the round; time-out uses the 1v1 tie-breaks (4.4).
// 3v3 only (3.3.2 - 3.3.5, 8.1.2):
//   - 200 Victory Points each; holding the capture point drains the enemy
//     1 VP/s; each defeat costs 20 VP; 0 VP ends the round
//   - respawn after 5 s, +5 s per further defeat, at 20 % HP, invincible
//     30 s and weakened (launcher locked, cannot capture) until the robot
//     reaches its resupply zone, which also heals 25 % max HP per second
//   - gold: 200 at the start, +200 at 3:59 and 2:59, +300 at 1:59 and 0:59,
//     +200 to the trailing team when the VP gap first reaches 70 and 140;
//     exchange in the resupply zone (17 mm 1 coin each, 42 mm 10)
//   - 42 mm hits do nothing while the attacking team's Hero has not fired
//     for 4 s or has been down for 3 s
//   - yellow also costs the offender's alive teammates 5 %; a Sentry's
//     chassis is cut for 2 s
//   - time-out: more VP, then more attack damage dealt, then more HP
//
// web/js/sim.js mirrors this file; web/test checks they agree.
module arc_ref_core #(
    parameter integer CLK_HZ = 100_000_000
) (
    input  wire          clk,
    input  wire          rst,

    input  wire          cmd_valid,
    input  wire [15:0]   cmd_id,
    input  wire [7:0]    cmd_len,
    input  wire [191:0]  cmd_data,

    input  wire [3:0]    btn_hit,      // one-cycle pulse per armor plate
    input  wire [2:0]    btn_target,   // robot slot the buttons hit

    output reg           tick_20ms,

    output reg  [2:0]    stage,
    output reg           paused,
    output reg  [15:0]   remain,
    output reg  [1:0]    winner,       // 0 draw / none, 1 red, 2 blue
    output reg  [7:0]    win_reason,
    output reg  [1:0]    first_dmg,    // 1v1: 1 red took first damage, 2 blue
    output reg  [1:0]    first_shot,   // 1v1: 1 red fired first, 2 blue
    output reg  [1:0]    cap_holder,   // 3v3: 0 none, 1 red, 2 blue, 3 contested
    output reg  [3:0]    game_type,    // 4 = 3v3, 5 = 1v1
    output reg  [2:0]    link_robot,   // slot whose view the real frames give
    output reg  [31:0]   unix_time,
    output reg  [15:0]   cfg_combat_time,
    output reg  [15:0]   cfg_setup_time,

    // Per-robot, packed slot 5 .. slot 0
    output wire [95:0]   hp_flat,
    output wire [95:0]   maxhp_flat,
    output wire [95:0]   heat10_flat,     // heat x10
    output wire [95:0]   heatlim_flat,
    output wire [95:0]   buf10_flat,      // buffer energy x0.1 J
    output wire [95:0]   power_flat,
    output wire [95:0]   plim_flat,
    output wire [95:0]   ammo_flat,
    output wire [95:0]   shots_flat,
    output wire [95:0]   cool_flat,
    output wire [95:0]   spdlim_flat,
    output wire [47:0]   yellow_flat,
    output wire [47:0]   rflags_flat,     // see below
    output wire [47:0]   rflags2_flat,
    output wire [47:0]   choff_flat,      // chassis cut, 100 ms ticks left
    output wire [95:0]   spdlk_flat,      // speed lock ticks, 0xFFFF = round
    output wire [95:0]   timer_flat,      // respawn ticks if respawning, else invincible ticks

    // Per-team, packed blue, red
    output wire [31:0]   vp_flat,
    output wire [31:0]   coins_flat,
    output wire [31:0]   dmg_flat,        // attack damage dealt
    output wire [1:0]    hero_live_flat,  // team's 42 mm hits currently count
    output wire [1:0]    in_resupply_flat,

    // Two event slots per cycle, packed {B, A}; arc_frame_gen queues A first.
    output reg  [1:0]    ev_valid,
    output reg  [5:0]    ev_robot,
    output reg  [15:0]   ev_kind,
    output reg  [15:0]   ev_detail,
    output reg  [31:0]   ev_hp,

    output reg           hurt_valid,    // link robot only (0x0206)
    output reg  [7:0]    hurt_byte,
    output reg           shot_valid,    // link robot only (0x0207)
    output reg  [7:0]    shot_freq,
    output reg  [31:0]   shot_speed,
    output reg           warn_valid,    // link team only (0x0104)
    output reg  [7:0]    warn_level,
    output reg  [7:0]    warn_id,
    output reg  [7:0]    warn_count,
    output reg           result_valid,  // 0x0002
    output reg           stage_valid    // stage/pause changed, push 0x0001 now
);
    localparam integer N = 6;

    localparam [2:0] ST_IDLE = 3'd0, ST_PREP = 3'd1, ST_CHECK = 3'd2,
                     ST_COUNT = 3'd3, ST_COMBAT = 3'd4, ST_RESULT = 3'd5;

    localparam [15:0] CHECK_S = 16'd15;
    localparam [15:0] COUNT_S = 16'd5;
    localparam [15:0] BUFFER_FULL_X10 = 16'd600;  // 60 J
    localparam [15:0] LOCK_ROUND = 16'hFFFF;
    localparam [15:0] YELLOW_WINDOW = 16'd300;    // 30 s in 100 ms ticks
    localparam [7:0]  CHASSIS_CUT = 8'd50;        // 5 s
    localparam [7:0]  SENTRY_CUT = 8'd20;         // 2 s
    localparam [15:0] INVINCIBLE = 16'd300;       // 30 s
    localparam [15:0] DMG_17 = 16'd20, DMG_42 = 16'd200, DMG_COLLISION = 16'd2;

    localparam [15:0] C_GAME = 16'hF001, C_CONFIG = 16'hF002, C_HIT = 16'hF003,
                      C_SHOOT = 16'hF004, C_PENALTY = 16'hF005, C_LIFE = 16'hF006,
                      C_POWER = 16'hF007, C_TIME = 16'hF008, C_ROBOT = 16'hF009,
                      C_ZONE = 16'hF00A, C_EXCHANGE = 16'hF00B;

    // Event kinds (0xF102)
    localparam [7:0] EV_HIT = 8'd1, EV_SHOT = 8'd2, EV_LOCK = 8'd3, EV_CHASSIS = 8'd4,
                     EV_YELLOW = 8'd5, EV_RED = 8'd6, EV_FORFEIT = 8'd7, EV_KILL = 8'd8,
                     EV_REVIVE = 8'd9, EV_DISCONNECT = 8'd10, EV_RECONNECT = 8'd11,
                     EV_OFFLINE_HP = 8'd12, EV_UNLOCK = 8'd13, EV_YELLOW_BOTH = 8'd14,
                     EV_EXCHANGE = 8'd15, EV_IMMUNE = 8'd16, EV_RESPAWN = 8'd17,
                     EV_CAPTURE = 8'd18, EV_YELLOW_TEAM = 8'd19;

    localparam [7:0] LK_HEAT = 8'd1, LK_HEAT_ROUND = 8'd2, LK_SPEED15 = 8'd3,
                     LK_SPEED20 = 8'd4, LK_SPEED_ROUND = 8'd5, LK_AMMO = 8'd6;

    localparam [7:0] WR_NONE = 8'd0, WR_DEFEAT = 8'd1, WR_HP = 8'd2, WR_FIRST_DMG = 8'd3,
                     WR_SHOTS = 8'd4, WR_FIRST_SHOT = 8'd5, WR_TIE = 8'd6, WR_FORFEIT = 8'd7,
                     WR_VP_ZERO = 8'd8, WR_VP = 8'd9, WR_DAMAGE = 8'd10, WR_TOTAL_HP = 8'd11;

    localparam [3:0] RS_ARMOR = 4'd0, RS_COLLISION = 4'd5;

    localparam integer TICK_DIV = CLK_HZ / 50;

    // ------------------------------------------------------- robot config
    reg        fielded [0:N-1];
    reg        cal42   [0:N-1];
    reg [15:0] maxhp   [0:N-1];
    reg [15:0] heatlim [0:N-1];
    reg [15:0] cool    [0:N-1];
    reg [15:0] plim    [0:N-1];
    reg [15:0] spdlim  [0:N-1];
    reg [15:0] allow0  [0:N-1];
    reg [15:0] p5      [0:N-1];   // 5 / 15 / 20 / 25 % of max HP, rounded
    reg [15:0] p15     [0:N-1];
    reg [15:0] p20     [0:N-1];
    reg [15:0] p25     [0:N-1];

    // -------------------------------------------------------- robot state
    reg [15:0] hp      [0:N-1];
    reg [15:0] heat10  [0:N-1];
    reg [15:0] buf10   [0:N-1];
    reg [15:0] power   [0:N-1];
    reg [15:0] ammo    [0:N-1];
    reg [15:0] shots   [0:N-1];
    reg [7:0]  yellow  [0:N-1];
    reg [1:0]  yel_k   [0:N-1];   // doubling level of the last yellow
    reg [15:0] yel_win [0:N-1];
    reg        red     [0:N-1];
    reg [1:0]  heat_lk [0:N-1];   // 0 none, 1 until heat 0, 2 round
    reg [15:0] spd_lk  [0:N-1];
    reg [7:0]  ch_off  [0:N-1];
    reg        disc    [0:N-1];
    reg [3:0]  sec_t   [0:N-1];   // 1 s divider for drain and healing
    reg [1:0]  zone    [0:N-1];   // 0 none, 1 resupply zone, 2 capture point
    reg [15:0] resp_t  [0:N-1];   // respawn ticks left
    reg [7:0]  defeats [0:N-1];
    reg [15:0] invinc  [0:N-1];
    reg        weak    [0:N-1];

    // --------------------------------------------------------- team state
    reg [15:0] vp      [0:1];
    reg [15:0] coins   [0:1];
    reg [15:0] dmg     [0:1];     // attack damage dealt to the other team
    reg [7:0]  hquiet  [0:1];     // ticks since the team's Hero fired 42 mm
    reg [7:0]  hdown   [0:1];     // ticks the team's Hero has been down
    reg [1:0]  bonus;             // VP-gap coin bonuses given (70, 140)
    reg [3:0]  vp_t;
    reg [7:0]  both_yellow;

    // -------------------------------------------------------- sequencing
    reg [31:0] tdiv;
    reg [2:0]  t5;
    reg [3:0]  t10;
    reg [3:0]  sub;
    reg [4:0]  step;      // 1 stage, 2..19 robot jobs, 20 teams
    reg [5:0]  pen_mask;  // robots still owed a 5 % penalty
    reg [7:0]  pen_kind;

    reg         cmd_pend;
    reg [15:0]  c_id;
    reg [7:0]   c_len;
    reg [191:0] c_data;
    reg [3:0]   btn_pend;
    reg [2:0]   btn_r;

    wire mode3 = (game_type == 4'd4);
    wire in_combat = (stage == ST_COMBAT) && !paused;

    function [15:0] pct_of;   // round(x * p / 100)
        input [15:0] x;
        input [7:0]  p;
        reg [23:0] n;
        reg [47:0] q;
        begin
            n = x * p + 24'd50;
            q = n * 48'd1342178;
            pct_of = q[42:27];
        end
    endfunction

    function [7:0] robot_id;
        input [2:0] r;
        robot_id = ((r >= 3'd3) ? 8'd100 : 8'd0) +
                   ((r == 3'd0 || r == 3'd3) ? 8'd1 : (r == 3'd1 || r == 3'd4) ? 8'd3 : 8'd7);
    endfunction

    function team_of;
        input [2:0] r;
        team_of = (r >= 3'd3);
    endfunction

    function [2:0] role_of;   // 0 hero, 1 infantry, 2 sentry
        input [2:0] r;
        role_of = (r >= 3'd3) ? r - 3'd3 : r;
    endfunction

    function alive;
        input [2:0] r;
        alive = fielded[r] && hp[r] != 16'd0;
    endfunction

    function shooter_on;
        input [2:0] r;
        shooter_on = alive(r) && !disc[r] && heat_lk[r] == 2'd0 && spd_lk[r] == 16'd0
                     && ammo[r] != 16'd0 && !weak[r];
    endfunction

    function [15:0] penalty_hp;
        input [15:0] h;
        input [15:0] ded;
        penalty_hp = (h == 16'd0) ? 16'd0 : (h <= ded) ? 16'd1 : h - ded;
    endfunction

    function [15:0] sat_sub;
        input [15:0] a;
        input [15:0] b;
        sat_sub = (a > b) ? a - b : 16'd0;
    endfunction

    // ---------------------------------------------------------- outputs
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : outs
            wire al  = fielded[g] && hp[g] != 16'd0;
            wire gim = al && !disc[g];
            wire chs = gim && ch_off[g] == 8'd0;
            wire hlk = heat_lk[g] != 2'd0;
            wire slk = spd_lk[g] != 16'd0;
            wire sht = gim && !hlk && !slk && ammo[g] != 16'd0 && !weak[g];
            assign hp_flat[16*g +: 16]      = hp[g];
            assign maxhp_flat[16*g +: 16]   = maxhp[g];
            assign heat10_flat[16*g +: 16]  = heat10[g];
            assign heatlim_flat[16*g +: 16] = heatlim[g];
            assign buf10_flat[16*g +: 16]   = buf10[g];
            assign power_flat[16*g +: 16]   = power[g];
            assign plim_flat[16*g +: 16]    = plim[g];
            assign ammo_flat[16*g +: 16]    = ammo[g];
            assign shots_flat[16*g +: 16]   = shots[g];
            assign cool_flat[16*g +: 16]    = cool[g];
            assign spdlim_flat[16*g +: 16]  = spdlim[g];
            assign yellow_flat[8*g +: 8]    = yellow[g];
            assign rflags_flat[8*g +: 8]    = {slk, hlk, disc[g], gim, chs, sht, red[g], al};
            assign rflags2_flat[8*g +: 8]   = {1'b0, zone[g], resp_t[g] != 16'd0,
                                               weak[g], invinc[g] != 16'd0, cal42[g], fielded[g]};
            assign choff_flat[8*g +: 8]     = ch_off[g];
            assign spdlk_flat[16*g +: 16]   = spd_lk[g];
            assign timer_flat[16*g +: 16]   = (resp_t[g] != 16'd0) ? resp_t[g] : invinc[g];
        end
        for (g = 0; g < 2; g = g + 1) begin : touts
            assign vp_flat[16*g +: 16]    = vp[g];
            assign coins_flat[16*g +: 16] = coins[g];
            assign dmg_flat[16*g +: 16]   = dmg[g];
            assign hero_live_flat[g]      = !(hquiet[g] >= 8'd40 || hdown[g] >= 8'd30 || !fielded[3*g]);
            assign in_resupply_flat[g]    = (zone[3*g] == 2'd1 && fielded[3*g] && hp[3*g] != 16'd0)
                                         || (zone[3*g+1] == 2'd1 && fielded[3*g+1] && hp[3*g+1] != 16'd0)
                                         || (zone[3*g+2] == 2'd1 && fielded[3*g+2] && hp[3*g+2] != 16'd0);
        end
    endgenerate

    // ------------------------------------------------------------ helpers
    task emit_ev;
        input        slot;
        input [2:0]  r;
        input [7:0]  kind;
        input [7:0]  detail;
        input [15:0] value;
        begin
            ev_valid[slot]         <= 1'b1;
            ev_robot[3*slot +: 3]  <= r;
            ev_kind[8*slot +: 8]   <= kind;
            ev_detail[8*slot +: 8] <= detail;
            ev_hp[16*slot +: 16]   <= value;
        end
    endtask

    task finish;
        input [1:0] w;
        input [7:0] why;
        begin
            if (stage != ST_RESULT) begin
                stage        <= ST_RESULT;
                remain       <= 16'd0;
                paused       <= 1'b0;
                winner       <= w;
                win_reason   <= why;
                result_valid <= 1'b1;
                stage_valid  <= 1'b1;
            end
        end
    endtask

    task lose_vp;
        input        t;
        input [15:0] n;
        reg   [15:0] v;
        begin
            v = sat_sub(vp[t], n);
            vp[t] <= v;
            if (v == 16'd0 && stage == ST_COMBAT) finish(t ? 2'd1 : 2'd2, WR_VP_ZERO);
        end
    endtask

    // Set HP after a loss and apply the consequences of a defeat.
    task set_hp;
        input [2:0]  r;
        input [15:0] nh;
        input        attack;   // counts as attack damage for the other team
        reg          t;
        begin
            t = team_of(r);
            hp[r] <= nh;
            if (attack && nh < hp[r]) dmg[~t] <= dmg[~t] + (hp[r] - nh);
            if (in_combat && first_dmg == 2'd0 && !mode3) first_dmg <= t ? 2'd2 : 2'd1;
            if (stage == ST_COMBAT && nh == 16'd0 && hp[r] != 16'd0) begin
                if (!mode3) begin
                    finish(t ? 2'd1 : 2'd2, WR_DEFEAT);
                end else begin
                    heat10[r] <= 16'd0;
                    buf10[r]  <= BUFFER_FULL_X10;
                    if (heat_lk[r] == 2'd1) heat_lk[r] <= 2'd0;
                    invinc[r] <= 16'd0;
                    weak[r]   <= 1'b0;
                    if (!red[r]) resp_t[r] <= {defeats[r] + 8'd1, 5'd0} + {defeats[r] + 8'd1, 4'd0}
                                              + {defeats[r] + 8'd1, 1'b0};   // 50 x n ticks
                    defeats[r] <= defeats[r] + 8'd1;
                    lose_vp(t, 16'd20);
                end
            end
        end
    endtask

    task warn;
        input [2:0] r;
        input [7:0] level;
        input [7:0] id;
        input [7:0] count;
        begin
            if (team_of(r) == team_of(link_robot)) begin
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
            for (i = 0; i < N; i = i + 1) begin
                hp[i] <= fielded[i] ? maxhp[i] : 16'd0;
                heat10[i] <= 16'd0;
                buf10[i] <= BUFFER_FULL_X10;
                ammo[i] <= allow0[i];
                shots[i] <= 16'd0;
                yellow[i] <= 8'd0;
                yel_k[i] <= 2'd0;
                yel_win[i] <= 16'd0;
                red[i] <= 1'b0;
                heat_lk[i] <= 2'd0;
                spd_lk[i] <= 16'd0;
                ch_off[i] <= 8'd0;
                disc[i] <= 1'b0;
                sec_t[i] <= 4'd0;
                zone[i] <= 2'd0;
                resp_t[i] <= 16'd0;
                defeats[i] <= 8'd0;
                invinc[i] <= 16'd0;
                weak[i] <= 1'b0;
            end
            for (i = 0; i < 2; i = i + 1) begin
                vp[i] <= 16'd200;
                coins[i] <= 16'd0;
                dmg[i] <= 16'd0;
                hquiet[i] <= 8'd255;
                hdown[i] <= 8'd0;
            end
            bonus <= 2'd0;
            vp_t <= 4'd0;
            cap_holder <= 2'd0;
            pen_mask <= 6'd0;
            both_yellow <= 8'd0;
            first_dmg <= 2'd0;
            first_shot <= 2'd0;
            winner <= 2'd0;
            win_reason <= WR_NONE;
        end
    endtask

    // 1v1 winning criteria (4.4) on slots 1 and 4; 3v3 (3.3.5).
    function [9:0] judge;
        input dummy;
        reg [17:0] th0, th1;
        begin
            if (mode3) begin
                th0 = (fielded[0] ? hp[0] : 16'd0) + (fielded[1] ? hp[1] : 16'd0) + (fielded[2] ? hp[2] : 16'd0);
                th1 = (fielded[3] ? hp[3] : 16'd0) + (fielded[4] ? hp[4] : 16'd0) + (fielded[5] ? hp[5] : 16'd0);
                if (vp[0] != vp[1])        judge = {(vp[0] > vp[1]) ? 2'd1 : 2'd2, WR_VP};
                else if (dmg[0] != dmg[1]) judge = {(dmg[0] > dmg[1]) ? 2'd1 : 2'd2, WR_DAMAGE};
                else if (th0 != th1)       judge = {(th0 > th1) ? 2'd1 : 2'd2, WR_TOTAL_HP};
                else                       judge = {2'd0, WR_TIE};
            end else begin
                if (hp[1] != hp[4])
                    judge = {(hp[1] > hp[4]) ? 2'd1 : 2'd2, WR_HP};
                else if (hp[1] != maxhp[1] && first_dmg != 2'd0)
                    judge = {(first_dmg == 2'd1) ? 2'd2 : 2'd1, WR_FIRST_DMG};
                else if (shots[1] != shots[4])
                    judge = {(shots[1] > shots[4]) ? 2'd1 : 2'd2, WR_SHOTS};
                else if (first_shot != 2'd0)
                    judge = {first_shot, WR_FIRST_SHOT};
                else
                    judge = {2'd0, WR_TIE};
            end
        end
    endfunction

    // Armor hit on slot r: kind 0 = 17 mm, 1 = collision, 2 = 42 mm.
    task hit;
        input [2:0] r;
        input [3:0] armor;
        input [1:0] kind;
        input       button;
        reg [15:0]  d;
        reg [15:0]  nh;
        reg         t;
        begin
            t = team_of(r);
            if (in_combat && alive(r) && !disc[r] && !(mode3 && invinc[r] != 16'd0)) begin
                if (kind == 2'd2 && mode3 && !hero_live_flat[~t]) begin
                    emit_ev(1'b0, r, EV_IMMUNE, {4'd0, armor}, hp[r]);
                end else begin
                    d  = (kind == 2'd1) ? DMG_COLLISION : (kind == 2'd2) ? DMG_42 : DMG_17;
                    nh = sat_sub(hp[r], d);
                    set_hp(r, nh, kind != 2'd1);
                    emit_ev(1'b0, r, EV_HIT, {button, kind == 2'd1, kind == 2'd2, 1'b0, armor}, nh);
                    if (r == link_robot) begin
                        hurt_valid <= 1'b1;
                        hurt_byte  <= {(kind == 2'd1) ? RS_COLLISION : RS_ARMOR, armor};
                    end
                end
            end
        end
    endtask

    task yellow_card;
        input [2:0] r;
        reg [7:0]  cnt;
        reg [1:0]  k;
        reg [15:0] nh;
        reg        t;
        begin
            t   = team_of(r);
            cnt = yellow[r] + 8'd1;
            k   = (yel_win[r] != 16'd0) ? ((yel_k[r] == 2'd3) ? 2'd3 : yel_k[r] + 2'd1) : 2'd0;
            yellow[r]  <= cnt;
            yel_k[r]   <= k;
            yel_win[r] <= YELLOW_WINDOW;
            warn(r, 8'd2, robot_id(r), cnt);
            if (cnt >= 8'd3) begin
                red[r] <= 1'b1;
                set_hp(r, 16'd0, 1'b1);
                emit_ev(1'b0, r, EV_YELLOW, cnt, 16'd0);
                emit_ev(1'b1, r, EV_RED, 8'd1, 16'd0);
            end else begin
                nh = penalty_hp(hp[r], p15[r] << k);
                if (nh != hp[r]) set_hp(r, nh, 1'b1);
                emit_ev(1'b0, r, EV_YELLOW, cnt, nh);
                if (mode3 && role_of(r) == 3'd2) ch_off[r] <= SENTRY_CUT;
            end
            if (mode3) begin       // alive teammates lose 5 %
                pen_kind <= EV_YELLOW_TEAM;
                pen_mask <= (t ? 6'b111000 : 6'b000111) & ~(6'd1 << r);
            end
        end
    endtask

    task heat_step;
        input [2:0] r;
        reg [15:0] h;
        reg [15:0] lim10, rnd10;
        begin
            if (!paused) begin
                h     = heat10[r];
                lim10 = (heatlim[r] << 3) + (heatlim[r] << 1);
                rnd10 = lim10 + (cal42[r] ? 16'd2000 : 16'd1000);
                if (in_combat && alive(r) && heat_lk[r] != 2'd2 && h > rnd10) begin
                    heat_lk[r] <= 2'd2;
                    emit_ev(1'b0, r, EV_LOCK, LK_HEAT_ROUND, hp[r]);
                end else if (in_combat && alive(r) && heat_lk[r] == 2'd0 && h > lim10) begin
                    heat_lk[r] <= 2'd1;
                    emit_ev(1'b0, r, EV_LOCK, LK_HEAT, hp[r]);
                end else if (heat_lk[r] == 2'd1 && h <= cool[r]) begin
                    heat_lk[r] <= 2'd0;
                    emit_ev(1'b0, r, EV_UNLOCK, LK_HEAT, hp[r]);
                end
                heat10[r] <= sat_sub(h, cool[r]);
            end
        end
    endtask

    task power_step;
        input [2:0] r;
        reg [15:0] d;
        reg [15:0] p;
        reg [16:0] refill;
        begin
            if (in_combat && alive(r) && !disc[r]) begin
                p = (ch_off[r] != 8'd0) ? 16'd0 : power[r];
                if (ch_off[r] != 8'd0) ch_off[r] <= ch_off[r] - 8'd1;
                if (p > plim[r]) begin
                    d = p - plim[r];
                    if (buf10[r] > d) begin
                        buf10[r] <= buf10[r] - d;
                    end else begin
                        buf10[r] <= 16'd0;
                        ch_off[r] <= CHASSIS_CUT;
                        emit_ev(1'b0, r, EV_CHASSIS, 8'd0, hp[r]);
                    end
                end else begin
                    refill = buf10[r] + (plim[r] - p);
                    buf10[r] <= (refill > BUFFER_FULL_X10) ? BUFFER_FULL_X10 : refill[15:0];
                end
            end else if (!paused && !(in_combat && fielded[r])) begin
                buf10[r] <= BUFFER_FULL_X10;
                ch_off[r] <= 8'd0;
            end
        end
    endtask

    task timer_step;
        input [2:0] r;
        reg [15:0] nh;
        reg [16:0] heal;
        begin
            if (in_combat && fielded[r]) begin
                if (yel_win[r] != 16'd0) yel_win[r] <= yel_win[r] - 16'd1;
                if (invinc[r] != 16'd0) invinc[r] <= invinc[r] - 16'd1;
                if (spd_lk[r] == 16'd1) begin
                    spd_lk[r] <= 16'd0;
                    emit_ev(1'b0, r, EV_UNLOCK, LK_SPEED15, hp[r]);
                end else if (spd_lk[r] != 16'd0 && spd_lk[r] != LOCK_ROUND) begin
                    spd_lk[r] <= spd_lk[r] - 16'd1;
                end
                if (resp_t[r] != 16'd0 && !disc[r]) begin
                    if (resp_t[r] == 16'd1) begin            // respawn
                        hp[r]     <= p20[r];
                        invinc[r] <= INVINCIBLE;
                        weak[r]   <= 1'b1;
                        emit_ev(1'b1, r, EV_RESPAWN, defeats[r], p20[r]);
                    end
                    resp_t[r] <= resp_t[r] - 16'd1;
                end
                sec_t[r] <= (sec_t[r] == 4'd9) ? 4'd0 : sec_t[r] + 4'd1;
                if (sec_t[r] == 4'd9 && alive(r)) begin
                    if (disc[r]) begin
                        nh = sat_sub(hp[r], p5[r]);
                        set_hp(r, nh, 1'b0);
                        emit_ev(1'b1, r, EV_OFFLINE_HP, 8'd0, nh);   // slot A may hold an unlock
                    end else if (mode3 && zone[r] == 2'd1) begin
                        heal = hp[r] + p25[r];
                        hp[r] <= (heal > maxhp[r]) ? maxhp[r] : heal[15:0];
                        weak[r]   <= 1'b0;      // also when it respawned in the zone
                        invinc[r] <= 16'd0;
                    end
                end
            end
        end
    endtask

    // Capture point, VP drain, Hero 42 mm timers, VP-gap coins.
    task team_step;
        reg [1:0]  pres;
        reg [1:0]  h;
        reg [15:0] gap;
        integer    i;
        begin
            if (in_combat && mode3) begin
                for (i = 0; i < 2; i = i + 1) begin
                    if (hquiet[i] != 8'd255) hquiet[i] <= hquiet[i] + 8'd1;
                    if (fielded[3*i] && (hp[3*i] == 16'd0 || disc[3*i]))
                        hdown[i] <= (hdown[i] == 8'd255) ? 8'd255 : hdown[i] + 8'd1;
                    else
                        hdown[i] <= 8'd0;
                end
                for (i = 0; i < 2; i = i + 1)
                    pres[i] = (alive(3*i)   && !disc[3*i]   && !weak[3*i]   && zone[3*i]   == 2'd2)
                           || (alive(3*i+1) && !disc[3*i+1] && !weak[3*i+1] && zone[3*i+1] == 2'd2)
                           || (alive(3*i+2) && !disc[3*i+2] && !weak[3*i+2] && zone[3*i+2] == 2'd2);
                if ((cap_holder == 2'd1 && pres[0]) || (cap_holder == 2'd2 && pres[1])) h = cap_holder;
                else if (pres == 2'b01) h = 2'd1;
                else if (pres == 2'b10) h = 2'd2;
                else if (pres == 2'b11) h = 2'd3;
                else h = 2'd0;
                if (h != cap_holder) begin
                    cap_holder <= h;
                    emit_ev(1'b0, 3'd0, EV_CAPTURE, {6'd0, h}, 16'd0);
                end
                if (vp_t == 4'd9) begin
                    vp_t <= 4'd0;
                    if (h == 2'd1) lose_vp(1'b1, 16'd1);
                    if (h == 2'd2) lose_vp(1'b0, 16'd1);
                end else begin
                    vp_t <= vp_t + 4'd1;
                end
                gap = (vp[0] > vp[1]) ? vp[0] - vp[1] : vp[1] - vp[0];
                if (gap >= 16'd70 && !bonus[0]) begin
                    bonus[0] <= 1'b1;
                    if (vp[0] < vp[1]) coins[0] <= coins[0] + 16'd200; else coins[1] <= coins[1] + 16'd200;
                end else if (gap >= 16'd140 && !bonus[1]) begin
                    bonus[1] <= 1'b1;
                    if (vp[0] < vp[1]) coins[0] <= coins[0] + 16'd200; else coins[1] <= coins[1] + 16'd200;
                end
            end
        end
    endtask

    task give_coins;
        input [15:0] n;
        begin
            coins[0] <= coins[0] + n;
            coins[1] <= coins[1] + n;
        end
    endtask

    task run_cmd;
        reg [2:0]  r;
        reg        t;
        reg [7:0]  a;
        reg [16:0] h;
        reg [15:0] sp, lim10, lk, n, cost;
        reg [7:0]  lkd;
        integer    i;
        begin
            r = (c_data[2:0] > 3'd5) ? 3'd5 : c_data[2:0];
            t = team_of(r);
            a = c_data[15:8];
            case (c_id)
                C_GAME: case (c_data[7:0])
                    8'd1: if (stage == ST_IDLE) begin
                        stage <= ST_PREP; remain <= cfg_setup_time; sub <= 4'd0;
                        paused <= 1'b0; stage_valid <= 1'b1;
                    end
                    8'd2: if (stage == ST_IDLE || stage == ST_PREP) begin
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
                    8'd6: begin
                        stage <= ST_IDLE; remain <= 16'd0; paused <= 1'b0;
                        reset_robots();
                        for (i = 0; i < N; i = i + 1) power[i] <= 16'd0;
                        warn_valid <= 1'b1; warn_level <= 8'd0; warn_id <= 8'd0; warn_count <= 8'd0;
                        stage_valid <= 1'b1;
                    end
                    default: ;
                endcase
                C_CONFIG: if (stage == ST_IDLE && c_len >= 8'd6) begin
                    game_type       <= c_data[3:0];
                    link_robot      <= (c_data[10:8] > 3'd5) ? 3'd5 : c_data[10:8];
                    cfg_combat_time <= c_data[31:16];
                    cfg_setup_time  <= c_data[47:32];
                    stage_valid     <= 1'b1;
                end
                // Stats per robot; also allowed in the setup period, when the
                // Infantry pilot picks a chassis and launcher type (3.1.2).
                C_ROBOT: if ((stage == ST_IDLE || stage == ST_PREP) && c_len >= 8'd15) begin
                    fielded[r] <= c_data[8];
                    cal42[r]   <= c_data[9];
                    maxhp[r]   <= c_data[31:16];
                    heatlim[r] <= c_data[47:32];
                    cool[r]    <= c_data[63:48];
                    plim[r]    <= c_data[79:64];
                    spdlim[r]  <= c_data[95:80];
                    allow0[r]  <= c_data[111:96];
                    p5[r]      <= pct_of(c_data[31:16], 8'd5);
                    p15[r]     <= pct_of(c_data[31:16], 8'd15);
                    p20[r]     <= pct_of(c_data[31:16], 8'd20);
                    p25[r]     <= pct_of(c_data[31:16], 8'd25);
                    hp[r]      <= c_data[8] ? c_data[31:16] : 16'd0;
                    ammo[r]    <= c_data[111:96];
                    stage_valid <= 1'b1;
                end
                C_HIT: hit(r, a[3:0], (c_len >= 8'd3) ? c_data[17:16] : 2'd0, 1'b0);
                C_SHOOT: if (in_combat && shooter_on(r)) begin
                    h = heat10[r] + (cal42[r] ? 17'd1000 : 17'd100);
                    heat10[r] <= h[16] ? 16'hFFFF : h[15:0];
                    ammo[r]  <= ammo[r] - 16'd1;
                    shots[r] <= shots[r] + 16'd1;
                    if (first_shot == 2'd0 && !mode3) first_shot <= t ? 2'd2 : 2'd1;
                    if (cal42[r] && role_of(r) == 3'd0) hquiet[t] <= 8'd0;
                    emit_ev(1'b0, r, EV_SHOT, a, ammo[r] - 16'd1);
                    sp = (c_len >= 8'd8) ? c_data[63:48] : 16'd0;
                    lim10 = (spdlim[r] << 3) + (spdlim[r] << 1);
                    if (sp > lim10) begin
                        if (cal42[r]) begin            // 42 mm: 1.1 / 1.2 x the limit
                            if (sp <= lim10 + spdlim[r])              begin lk = 16'd150;    lkd = LK_SPEED15; end
                            else if (sp <= lim10 + (spdlim[r] << 1)) begin lk = 16'd200;    lkd = LK_SPEED20; end
                            else                                      begin lk = LOCK_ROUND; lkd = LK_SPEED_ROUND; end
                        end else begin                 // 17 mm: +5 / +10 m/s
                            if (sp - lim10 < 16'd50)       begin lk = 16'd150;    lkd = LK_SPEED15; end
                            else if (sp - lim10 < 16'd100) begin lk = 16'd200;    lkd = LK_SPEED20; end
                            else                           begin lk = LOCK_ROUND; lkd = LK_SPEED_ROUND; end
                        end
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
                    8'd1: begin                                  // both teams yellow
                        both_yellow <= both_yellow + 8'd1;
                        pen_kind <= EV_YELLOW_BOTH;
                        pen_mask <= 6'b111111;
                        warn(link_robot, 8'd1, 8'd0, both_yellow + 8'd1);
                    end
                    8'd2: yellow_card(r);
                    8'd3: begin
                        red[r] <= 1'b1;
                        set_hp(r, 16'd0, 1'b1);
                        emit_ev(1'b0, r, EV_RED, 8'd0, 16'd0);
                        warn(r, 8'd3, robot_id(r), 8'd1);
                    end
                    8'd4: if (stage >= ST_PREP && stage <= ST_COMBAT) begin
                        if (mode3) begin
                            vp[t] <= 16'd0;
                        end else if (stage != ST_COMBAT) begin
                            hp[r] <= 16'd0;
                            hp[t ? 1 : 4] <= maxhp[t ? 1 : 4];
                        end
                        emit_ev(1'b0, r, EV_FORFEIT, 8'd0, hp[r]);
                        warn(r, 8'd4, 8'd0, 8'd1);
                        finish(t ? 2'd1 : 2'd2, WR_FORFEIT);
                    end
                    default: ;
                endcase
                C_LIFE: case (a)
                    8'd0: if (fielded[r]) begin
                        set_hp(r, 16'd0, 1'b0);
                        emit_ev(1'b0, r, EV_KILL, 8'd0, 16'd0);
                    end
                    8'd1: if (fielded[r]) begin
                        hp[r] <= maxhp[r]; heat10[r] <= 16'd0; red[r] <= 1'b0;
                        heat_lk[r] <= 2'd0; spd_lk[r] <= 16'd0; disc[r] <= 1'b0;
                        resp_t[r] <= 16'd0; weak[r] <= 1'b0; invinc[r] <= 16'd0;
                        emit_ev(1'b0, r, EV_REVIVE, 8'd0, maxhp[r]);
                    end
                    8'd2: if (fielded[r] && !disc[r]) begin
                        disc[r] <= 1'b1;
                        sec_t[r] <= 4'd0;
                        emit_ev(1'b0, r, EV_DISCONNECT, 8'd0, hp[r]);
                    end
                    8'd3: if (disc[r]) begin
                        disc[r] <= 1'b0;
                        emit_ev(1'b0, r, EV_RECONNECT, 8'd0, hp[r]);
                    end
                    default: ;
                endcase
                C_POWER: power[r] <= c_data[23:8];
                C_TIME:  unix_time <= c_data[31:0];
                C_ZONE: begin
                    zone[r] <= a[1:0];
                    if (mode3 && a[1:0] == 2'd1 && alive(r)) begin   // resupply clears both
                        weak[r]   <= 1'b0;
                        invinc[r] <= 16'd0;
                    end
                end
                C_EXCHANGE: begin
                    n    = c_data[23:8];
                    cost = cal42[r] ? (n << 3) + (n << 1) : n;
                    if (mode3 && in_combat && alive(r) && role_of(r) != 3'd2 && zone[r] == 2'd1
                        && n != 16'd0 && coins[t] >= cost) begin
                        coins[t] <= coins[t] - cost;
                        ammo[r]  <= ammo[r] + n;
                        emit_ev(1'b0, r, EV_EXCHANGE, 8'd0, ammo[r] + n);
                    end else begin
                        emit_ev(1'b0, r, EV_EXCHANGE, 8'd1, ammo[r]);
                    end
                end
                default: ;
            endcase
        end
    endtask

    // Step number -> robot slot and job for steps 2..19.
    wire [4:0] sj = step - 5'd2;
    wire [2:0] st_r  = sj / 3;
    wire [1:0] st_ph = sj % 3;

    reg [3:0] bclr;
    reg [5:0] pbit;
    reg [2:0] pr;
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
            tdiv <= 32'd0; t5 <= 3'd0; t10 <= 4'd0; sub <= 4'd0; step <= 5'd0;
            stage <= ST_IDLE; paused <= 1'b0; remain <= 16'd0;
            game_type <= 4'd5;
            link_robot <= 3'd1;
            unix_time <= 32'd0;
            cfg_combat_time <= 16'd120;
            cfg_setup_time  <= 16'd120;
            // 1v1 Infantry (table 4-2) in every slot; only 1 and 4 fielded.
            for (i = 0; i < N; i = i + 1) begin
                fielded[i] <= (i == 1 || i == 4);
                cal42[i] <= 1'b0;
                maxhp[i] <= 16'd200; heatlim[i] <= 16'd80; cool[i] <= 16'd12;
                plim[i] <= 16'd120; spdlim[i] <= 16'd25; allow0[i] <= 16'd200;
                p5[i] <= 16'd10; p15[i] <= 16'd30; p20[i] <= 16'd40; p25[i] <= 16'd50;
                hp[i] <= (i == 1 || i == 4) ? 16'd200 : 16'd0;
                heat10[i] <= 16'd0; buf10[i] <= BUFFER_FULL_X10; power[i] <= 16'd0;
                ammo[i] <= 16'd200; shots[i] <= 16'd0; yellow[i] <= 8'd0; yel_k[i] <= 2'd0;
                yel_win[i] <= 16'd0; red[i] <= 1'b0; heat_lk[i] <= 2'd0; spd_lk[i] <= 16'd0;
                ch_off[i] <= 8'd0; disc[i] <= 1'b0; sec_t[i] <= 4'd0; zone[i] <= 2'd0;
                resp_t[i] <= 16'd0; defeats[i] <= 8'd0; invinc[i] <= 16'd0; weak[i] <= 1'b0;
            end
            for (i = 0; i < 2; i = i + 1) begin
                vp[i] <= 16'd200; coins[i] <= 16'd0; dmg[i] <= 16'd0;
                hquiet[i] <= 8'd255; hdown[i] <= 8'd0;
            end
            bonus <= 2'd0; vp_t <= 4'd0; cap_holder <= 2'd0; both_yellow <= 8'd0;
            pen_mask <= 6'd0; pen_kind <= 8'd0;
            first_dmg <= 2'd0; first_shot <= 2'd0; winner <= 2'd0; win_reason <= WR_NONE;
            cmd_pend <= 1'b0; btn_pend <= 4'd0; btn_r <= 3'd1;
            ev_robot <= 6'd0; ev_kind <= 16'd0; ev_detail <= 16'd0; ev_hp <= 32'd0;
            hurt_byte <= 8'd0; shot_freq <= 8'd0; shot_speed <= 32'd0;
            warn_level <= 8'd0; warn_id <= 8'd0; warn_count <= 8'd0;
        end else begin
            // 50 Hz base tick
            if (tdiv == TICK_DIV - 1) begin
                tdiv <= 32'd0;
                tick_20ms <= 1'b1;
                if (t5 == 3'd4) begin
                    t5 <= 3'd0;
                    step <= 5'd1;
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

            // One job per cycle, at most two event pulses per cycle.
            if (step != 5'd0) begin
                if (step == 5'd1) begin
                    if (!paused && stage >= ST_PREP && stage <= ST_COMBAT) begin
                        if (sub == 4'd9) begin
                            sub <= 4'd0;
                            if (remain > 16'd1) begin
                                remain <= remain - 16'd1;
                                // 3v3 gold schedule (table 3-10), by time left
                                if (stage == ST_COMBAT && mode3) begin
                                    if (remain == 16'd240 || remain == 16'd180) give_coins(16'd200);
                                    if (remain == 16'd120 || remain == 16'd60)  give_coins(16'd300);
                                end
                            end else begin
                                case (stage)
                                    ST_PREP: begin
                                        stage <= ST_CHECK; remain <= CHECK_S; stage_valid <= 1'b1;
                                        reset_robots();
                                    end
                                    ST_CHECK: begin
                                        stage <= ST_COUNT; remain <= COUNT_S; stage_valid <= 1'b1;
                                    end
                                    ST_COUNT: begin
                                        stage <= ST_COMBAT; remain <= cfg_combat_time; stage_valid <= 1'b1;
                                        if (mode3) give_coins(16'd200);
                                    end
                                    default:
                                        finish(judge(1'b0) >> 8, judge(1'b0));
                                endcase
                            end
                        end else begin
                            sub <= sub + 4'd1;
                        end
                    end
                end else if (step <= 5'd19) begin
                    if (fielded[st_r]) begin
                        case (st_ph)
                            2'd0:    heat_step(st_r);
                            2'd1:    power_step(st_r);
                            default: timer_step(st_r);
                        endcase
                    end
                end else begin
                    team_step();
                end
                step <= (step == 5'd20) ? 5'd0 : step + 5'd1;
            end else if (pen_mask != 6'd0) begin
                // 5 % penalties to several robots, one per cycle
                pbit = pen_mask & (~pen_mask + 6'd1);
                pr = pbit[0] ? 3'd0 : pbit[1] ? 3'd1 : pbit[2] ? 3'd2 :
                     pbit[3] ? 3'd3 : pbit[4] ? 3'd4 : 3'd5;
                if (alive(pr)) begin
                    set_hp(pr, penalty_hp(hp[pr], p5[pr]), pen_kind == EV_YELLOW_TEAM);
                    emit_ev(1'b0, pr, pen_kind, (pen_kind == EV_YELLOW_BOTH) ? both_yellow : 8'd0,
                            penalty_hp(hp[pr], p5[pr]));
                end
                pen_mask <= pen_mask & ~pbit;
            end else if (cmd_pend) begin
                cmd_pend <= 1'b0;
                run_cmd();
            end else if (btn_pend != 4'd0) begin
                if      (btn_pend[0]) begin bclr = 4'b0001; hit(btn_r, 4'd0, 2'd0, 1'b1); end
                else if (btn_pend[1]) begin bclr = 4'b0010; hit(btn_r, 4'd1, 2'd0, 1'b1); end
                else if (btn_pend[2]) begin bclr = 4'b0100; hit(btn_r, 4'd2, 2'd0, 1'b1); end
                else                  begin bclr = 4'b1000; hit(btn_r, 4'd3, 2'd0, 1'b1); end
            end

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
