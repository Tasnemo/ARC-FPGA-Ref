`timescale 1ns / 1ps
// Referee core: match stages, timer, and per-robot HP / barrel heat / chassis
// buffer energy for two robots (0 = red standard, 1 = blue standard).
//
// Inputs are control frames already decoded by arc_rx_parser (cmd_*) and
// debounced armor-hit pulses from the board buttons. Outputs are the live
// state (read by arc_frame_gen) plus one-cycle event pulses.
//
// Rule numbers here are placeholders that are easy to change; see
// docs/protocol.md ("Rules model"). The JS emulator in web/js/sim.js mirrors
// this file and has to be kept in step with it.
module arc_ref_core #(
    parameter integer CLK_HZ = 100_000_000
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         cmd_valid,
    input  wire [15:0]  cmd_id,
    input  wire [7:0]   cmd_len,
    input  wire [127:0] cmd_data,

    input  wire [3:0]   btn_hit,      // one-cycle pulse per armor plate
    input  wire         btn_target,   // robot the buttons hit

    output reg          tick_20ms,

    output reg  [2:0]   stage,
    output reg          paused,
    output reg  [15:0]  remain,
    output reg  [1:0]   winner,       // 0 draw / none, 1 red, 2 blue
    output reg  [3:0]   game_type,
    output reg          link_robot,
    output reg  [31:0]  unix_time,

    output reg  [15:0]  cfg_combat_time,
    output reg  [15:0]  cfg_max_hp,
    output reg  [15:0]  cfg_heat_limit,
    output reg  [15:0]  cfg_cooling,
    output reg  [15:0]  cfg_power_limit,
    output reg  [15:0]  cfg_hit_dmg,

    // Per-robot state, packed {robot1, robot0}
    output wire [31:0]  hp_flat,
    output wire [31:0]  heat_flat,     // integer heat
    output wire [31:0]  buffer_flat,   // integer joules
    output wire [31:0]  power_flat,    // watts (simulated draw)
    output wire [15:0]  yellow_flat,
    output wire [1:0]   alive_flat,
    output wire [1:0]   red_card_flat,

    output reg          ev_valid,
    output reg          ev_robot,
    output reg  [7:0]   ev_kind,
    output reg  [7:0]   ev_detail,
    output reg  [15:0]  ev_hp,

    output reg          hurt_valid,    // link robot only (0x0206)
    output reg  [7:0]   hurt_byte,
    output reg          shot_valid,    // link robot only (0x0207)
    output reg  [7:0]   shot_freq,
    output reg  [31:0]  shot_speed,
    output reg          warn_valid,    // link robot only (0x0104)
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
    localparam [7:0] EV_HIT = 8'd1, EV_SHOT = 8'd2, EV_OVERHEAT = 8'd3,
                     EV_OVERPOWER = 8'd4, EV_YELLOW = 8'd5, EV_RED = 8'd6,
                     EV_FORFEIT = 8'd7, EV_KILL = 8'd8, EV_REVIVE = 8'd9;

    // 0x0206 HP_deduction_reason
    localparam [3:0] RS_ARMOR = 4'd0, RS_HEAT = 4'd3, RS_POWER = 4'd4;

    localparam integer TICK_DIV = CLK_HZ / 50;

    reg [15:0] hp     [0:1];
    reg [15:0] heat10 [0:1];   // heat x10
    reg [15:0] buf10  [0:1];   // buffer energy x0.1 J
    reg [15:0] power  [0:1];
    reg [7:0]  yellow [0:1];
    reg        red    [0:1];

    reg [31:0] tdiv;
    reg [2:0]  t5;     // 20 ms ticks within 100 ms
    reg [3:0]  t10;    // 100 ms ticks within 1 s (wall clock)
    reg [3:0]  sub;    // 100 ms ticks within 1 s (match timer)
    reg [2:0]  step;   // 100 ms housekeeping, one job per cycle

    reg         cmd_pend;
    reg [15:0]  c_id;
    reg [7:0]   c_len;
    reg [127:0] c_data;
    reg [3:0]   btn_pend;
    reg         btn_r;

    wire in_combat = (stage == ST_COMBAT) && !paused;
    wire [15:0] heat_limit10 = (cfg_heat_limit << 3) + (cfg_heat_limit << 1);

    // x / 10 for x < 65536 (exact), used to report heat and buffer
    function [15:0] div10;
        input [15:0] x;
        reg [31:0] p;
        begin
            p = x * 32'd52429;
            div10 = {3'b000, p[31:19]};
        end
    endfunction

    function [7:0] robot_id;
        input r;
        robot_id = r ? 8'd103 : 8'd3;
    endfunction

    assign hp_flat       = {hp[1], hp[0]};
    assign heat_flat     = {div10(heat10[1]), div10(heat10[0])};
    assign buffer_flat   = {div10(buf10[1]), div10(buf10[0])};
    assign power_flat    = {power[1], power[0]};
    assign yellow_flat   = {yellow[1], yellow[0]};
    assign alive_flat    = {hp[1] != 16'd0, hp[0] != 16'd0};
    assign red_card_flat = {red[1], red[0]};

    task emit_ev;
        input       r;
        input [7:0] kind;
        input [7:0] detail;
        input [15:0] hp_after;
        begin
            ev_valid  <= 1'b1;
            ev_robot  <= r;
            ev_kind   <= kind;
            ev_detail <= detail;
            ev_hp     <= hp_after;
        end
    endtask

    task damage;
        input        r;
        input [15:0] dmg;
        input [7:0]  kind;
        input [7:0]  detail;
        input [3:0]  reason;
        input [3:0]  armor;
        reg   [15:0] nh;
        begin
            nh = (hp[r] > dmg) ? hp[r] - dmg : 16'd0;
            hp[r] <= nh;
            emit_ev(r, kind, detail, nh);
            if (r == link_robot) begin
                hurt_valid <= 1'b1;
                hurt_byte  <= {reason, armor};
            end
        end
    endtask

    task warn;
        input       r;
        input [7:0] level;
        input [7:0] count;
        begin
            if (r == link_robot) begin
                warn_valid <= 1'b1;
                warn_level <= level;
                warn_id    <= robot_id(r);
                warn_count <= count;
            end
        end
    endtask

    task reset_robots;
        begin
            hp[0] <= cfg_max_hp;  hp[1] <= cfg_max_hp;
            heat10[0] <= 16'd0;   heat10[1] <= 16'd0;
            buf10[0] <= BUFFER_FULL_X10; buf10[1] <= BUFFER_FULL_X10;
            yellow[0] <= 8'd0;    yellow[1] <= 8'd0;
            red[0] <= 1'b0;       red[1] <= 1'b0;
        end
    endtask

    task finish;
        input [1:0] w;
        begin
            stage        <= ST_RESULT;
            remain       <= 16'd0;
            paused       <= 1'b0;
            winner       <= w;
            result_valid <= 1'b1;
            stage_valid  <= 1'b1;
        end
    endtask

    // Heat: cool, then penalise if over the limit.
    task heat_step;
        input r;
        reg [15:0] h;
        reg [15:0] over;
        begin
            if (!paused) begin
                h = (heat10[r] > cfg_cooling) ? heat10[r] - cfg_cooling : 16'd0;
                heat10[r] <= h;
                if (in_combat && hp[r] != 16'd0 && h > heat_limit10) begin
                    over = h - heat_limit10;
                    damage(r, (over >> 6) + 16'd1, EV_OVERHEAT, 8'd0, RS_HEAT, 4'd0);
                end
            end
        end
    endtask

    // Chassis power: drain buffer while over the limit, then penalise.
    task power_step;
        input r;
        reg [15:0] d;
        reg [16:0] refill;
        begin
            if (in_combat && hp[r] != 16'd0) begin
                if (power[r] > cfg_power_limit) begin
                    d = power[r] - cfg_power_limit;
                    if (buf10[r] > d) begin
                        buf10[r] <= buf10[r] - d;
                    end else begin
                        buf10[r] <= 16'd0;
                        damage(r, (d >> 2) + 16'd1, EV_OVERPOWER, 8'd0, RS_POWER, 4'd0);
                    end
                end else begin
                    refill = buf10[r] + (cfg_power_limit - power[r]);
                    buf10[r] <= (refill > BUFFER_FULL_X10) ? BUFFER_FULL_X10 : refill[15:0];
                end
            end else if (!paused) begin
                buf10[r] <= BUFFER_FULL_X10;
            end
        end
    endtask

    task hit;
        input       r;
        input [7:0] detail;   // armor id, bit 7 = physical button
        begin
            if (in_combat && hp[r] != 16'd0)
                damage(r, cfg_hit_dmg, EV_HIT, detail, RS_ARMOR, detail[3:0]);
        end
    endtask

    task run_cmd;
        reg        r;
        reg [7:0]  a;
        reg [16:0] h;
        begin
            r = c_data[0];
            a = c_data[15:8];
            case (c_id)
                C_GAME: case (c_data[7:0])
                    8'd1: if (stage == ST_IDLE) begin           // PREP
                        stage <= ST_PREP; stage_valid <= 1'b1;
                    end
                    8'd2: if (stage == ST_IDLE || stage == ST_PREP) begin  // START
                        stage <= ST_CHECK; remain <= CHECK_S; sub <= 4'd0;
                        paused <= 1'b0; winner <= 2'd0;
                        reset_robots();
                        stage_valid <= 1'b1;
                    end
                    8'd3: if (stage >= ST_CHECK && stage <= ST_COMBAT) begin  // PAUSE
                        paused <= 1'b1; stage_valid <= 1'b1;
                    end
                    8'd4: if (paused) begin                       // RESUME
                        paused <= 1'b0; stage_valid <= 1'b1;
                    end
                    8'd5: if (stage >= ST_PREP && stage <= ST_COMBAT)  // END
                        finish(hp[0] > hp[1] ? 2'd1 : hp[1] > hp[0] ? 2'd2 : 2'd0);
                    8'd6: begin                                   // RESET
                        stage <= ST_IDLE; remain <= 16'd0; paused <= 1'b0;
                        winner <= 2'd0;
                        reset_robots();
                        power[0] <= 16'd0; power[1] <= 16'd0;
                        stage_valid <= 1'b1;
                    end
                    default: ;
                endcase
                C_CONFIG: if (stage == ST_IDLE && c_len >= 8'd14) begin
                    game_type       <= c_data[3:0];
                    link_robot      <= c_data[8];
                    cfg_combat_time <= c_data[31:16];
                    cfg_max_hp      <= c_data[47:32];
                    cfg_heat_limit  <= c_data[63:48];
                    cfg_cooling     <= c_data[79:64];
                    cfg_power_limit <= c_data[95:80];
                    cfg_hit_dmg     <= c_data[111:96];
                    hp[0] <= c_data[47:32];
                    hp[1] <= c_data[47:32];
                    stage_valid <= 1'b1;
                end
                C_HIT: hit(r, {6'd0, a[1:0]});
                C_SHOOT: if (in_combat && hp[r] != 16'd0) begin
                    h = heat10[r] + 17'd100;               // 17 mm: +10 heat
                    heat10[r] <= h[16] ? 16'hFFFF : h[15:0];
                    emit_ev(r, EV_SHOT, a, hp[r]);
                    if (r == link_robot) begin
                        shot_valid <= 1'b1;
                        shot_freq  <= a;
                        shot_speed <= c_data[47:16];
                    end
                end
                C_PENALTY: case (a)
                    8'd2: begin                                   // yellow card
                        yellow[r] <= yellow[r] + 8'd1;
                        emit_ev(r, EV_YELLOW, yellow[r] + 8'd1, hp[r]);
                        warn(r, 8'd2, yellow[r] + 8'd1);
                    end
                    8'd3: begin                                   // red card
                        red[r] <= 1'b1;
                        hp[r]  <= 16'd0;
                        emit_ev(r, EV_RED, 8'd0, 16'd0);
                        warn(r, 8'd3, 8'd1);
                    end
                    8'd4: if (stage >= ST_PREP && stage <= ST_COMBAT) begin  // forfeit
                        emit_ev(r, EV_FORFEIT, 8'd0, hp[r]);
                        warn(r, 8'd4, 8'd1);
                        finish(r ? 2'd1 : 2'd2);
                    end
                    default: ;
                endcase
                C_LIFE: if (a == 8'd0) begin
                    hp[r] <= 16'd0;
                    emit_ev(r, EV_KILL, 8'd0, 16'd0);
                end else begin
                    hp[r]     <= cfg_max_hp;
                    heat10[r] <= 16'd0;
                    red[r]    <= 1'b0;
                    emit_ev(r, EV_REVIVE, 8'd0, cfg_max_hp);
                end
                C_POWER: power[r] <= c_data[23:8];
                C_TIME:  unix_time <= c_data[31:0];
                default: ;
            endcase
        end
    endtask

    reg [3:0] bclr;

    always @(posedge clk) begin
        bclr          = 4'd0;
        tick_20ms    <= 1'b0;
        ev_valid     <= 1'b0;
        hurt_valid   <= 1'b0;
        shot_valid   <= 1'b0;
        warn_valid   <= 1'b0;
        result_valid <= 1'b0;
        stage_valid  <= 1'b0;

        if (rst) begin
            tdiv <= 32'd0; t5 <= 3'd0; t10 <= 4'd0; sub <= 4'd0; step <= 3'd0;
            stage <= ST_IDLE; paused <= 1'b0; remain <= 16'd0; winner <= 2'd0;
            game_type <= 4'd5;             // RMUL 1v1
            link_robot <= 1'b0;
            unix_time <= 32'd0;
            cfg_combat_time <= 16'd180;
            cfg_max_hp      <= 16'd200;
            cfg_heat_limit  <= 16'd100;
            cfg_cooling     <= 16'd20;
            cfg_power_limit <= 16'd60;
            cfg_hit_dmg     <= 16'd10;
            hp[0] <= 16'd200; hp[1] <= 16'd200;
            heat10[0] <= 16'd0; heat10[1] <= 16'd0;
            buf10[0] <= BUFFER_FULL_X10; buf10[1] <= BUFFER_FULL_X10;
            power[0] <= 16'd0; power[1] <= 16'd0;
            yellow[0] <= 8'd0; yellow[1] <= 8'd0;
            red[0] <= 1'b0; red[1] <= 1'b0;
            cmd_pend <= 1'b0; btn_pend <= 4'd0; btn_r <= 1'b0;
            ev_robot <= 1'b0; ev_kind <= 8'd0; ev_detail <= 8'd0; ev_hp <= 16'd0;
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

            // One job per cycle, so at most one event pulse per cycle.
            if (step != 3'd0) begin
                case (step)
                    3'd1: if (!paused && stage >= ST_CHECK && stage <= ST_COMBAT) begin
                        if (sub == 4'd9) begin
                            sub <= 4'd0;
                            if (remain > 16'd1) begin
                                remain <= remain - 16'd1;
                            end else begin
                                case (stage)
                                    ST_CHECK: begin
                                        stage <= ST_COUNT; remain <= COUNT_S; stage_valid <= 1'b1;
                                    end
                                    ST_COUNT: begin
                                        stage <= ST_COMBAT; remain <= cfg_combat_time; stage_valid <= 1'b1;
                                    end
                                    default:
                                        finish(hp[0] > hp[1] ? 2'd1 : hp[1] > hp[0] ? 2'd2 : 2'd0);
                                endcase
                            end
                        end else begin
                            sub <= sub + 4'd1;
                        end
                    end
                    3'd2: heat_step(1'b0);
                    3'd3: power_step(1'b0);
                    3'd4: heat_step(1'b1);
                    3'd5: power_step(1'b1);
                    default: ;
                endcase
                step <= (step == 3'd5) ? 3'd0 : step + 3'd1;
            end else if (cmd_pend) begin
                cmd_pend <= 1'b0;
                run_cmd();
            end else if (btn_pend != 4'd0) begin
                if      (btn_pend[0]) begin bclr = 4'b0001; hit(btn_r, 8'h80); end
                else if (btn_pend[1]) begin bclr = 4'b0010; hit(btn_r, 8'h81); end
                else if (btn_pend[2]) begin bclr = 4'b0100; hit(btn_r, 8'h82); end
                else                  begin bclr = 4'b1000; hit(btn_r, 8'h83); end
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
