`timescale 1ns / 1ps
// Builds referee-protocol frames from the core state and writes them byte by
// byte into the TX FIFO. Layouts follow the RoboMaster 2026 University Series
// Communication Protocol, which ARCC 2026 uses (Site Manual table 1-2).
//
// Real referee frames (as the link robot would receive them):
//   0x0001 game status      1 Hz + on stage change
//   0x0002 game result      on match end
//   0x0003 ally robot HP    ~3 Hz
//   0x0104 referee warning  on penalty + 1 Hz
//   0x0201 robot status     10 Hz
//   0x0202 buffer and heat  10 Hz
//   0x0206 hurt data        on armor hit / collision
//   0x0207 shoot data       on shot
// Server-side frames for the browser console only:
//   0xF101 server state     10 Hz
//   0xF102 event            on every event, either robot
//
// The payload of each frame is captured into a register when the frame
// starts, so multi-byte fields never tear.
module arc_frame_gen (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick_20ms,

    input  wire [2:0]  stage,
    input  wire        paused,
    input  wire [15:0] remain,
    input  wire [1:0]  winner,
    input  wire [7:0]  win_reason,
    input  wire [1:0]  first_dmg,
    input  wire [1:0]  first_shot,
    input  wire [3:0]  game_type,
    input  wire        link_robot,
    input  wire [31:0] unix_time,
    input  wire [15:0] cfg_combat_time,
    input  wire [15:0] cfg_max_hp,
    input  wire [15:0] cfg_heat_limit,
    input  wire [15:0] cfg_cooling,
    input  wire [15:0] cfg_power_limit,
    input  wire [15:0] cfg_hit_dmg,
    input  wire [15:0] cfg_setup_time,
    input  wire [15:0] cfg_speed_limit,
    input  wire [31:0] hp_flat,
    input  wire [31:0] heat_flat,
    input  wire [31:0] buffer_flat,
    input  wire [31:0] power_flat,
    input  wire [31:0] allowance_flat,
    input  wire [31:0] shots_flat,
    input  wire [15:0] yellow_flat,
    input  wire [15:0] rflags_flat,
    input  wire [15:0] lock_s_flat,
    input  wire [15:0] chassis_ds_flat,
    input  wire [15:0] rx_ok,
    input  wire [15:0] rx_err,

    input  wire [1:0]  ev_valid,
    input  wire [1:0]  ev_robot,
    input  wire [15:0] ev_kind,
    input  wire [15:0] ev_detail,
    input  wire [31:0] ev_hp,
    input  wire        hurt_valid,
    input  wire [7:0]  hurt_byte,
    input  wire        shot_valid,
    input  wire [7:0]  shot_freq,
    input  wire [31:0] shot_speed,
    input  wire        warn_valid,
    input  wire [7:0]  warn_level,
    input  wire [7:0]  warn_id,
    input  wire [7:0]  warn_count,
    input  wire        result_valid,
    input  wire        stage_valid,

    output reg         fifo_wr,
    output reg  [7:0]  fifo_din,
    input  wire [10:0] fifo_free
);
    `include "arc_crc.vh"

    localparam integer PLW = 66 * 8;   // largest payload (0xF101)

    // Pending-frame slots, highest priority first
    localparam integer P_HURT = 0, P_SHOT = 1, P_WARN = 2, P_RESULT = 3,
                       P_STAT = 4, P_EV = 5, P_RS = 6, P_PH = 7, P_HP = 8,
                       P_SRV = 9, NP = 10;

    // ---------------------------------------------------------------- state
    wire        lr  = link_robot;
    wire [15:0] hp0 = hp_flat[15:0], hp1 = hp_flat[31:16];
    wire [7:0]  rf0 = rflags_flat[7:0], rf1 = rflags_flat[15:8];
    wire [7:0]  l_flags = lr ? rf1 : rf0;

    // Per-robot block of 0xF101 (22 bytes). Built from plain wires: simulators
    // do not re-evaluate continuous assigns through functions that read
    // module signals.
    wire [8*22-1:0] blk0 = {chassis_ds_flat[7:0], lock_s_flat[7:0], rflags_flat[7:0],
                            yellow_flat[7:0], shots_flat[15:0], allowance_flat[15:0],
                            cfg_power_limit, power_flat[15:0], buffer_flat[15:0],
                            cfg_heat_limit, heat_flat[15:0], cfg_max_hp, hp_flat[15:0]};
    wire [8*22-1:0] blk1 = {chassis_ds_flat[15:8], lock_s_flat[15:8], rflags_flat[15:8],
                            yellow_flat[15:8], shots_flat[31:16], allowance_flat[31:16],
                            cfg_power_limit, power_flat[31:16], buffer_flat[31:16],
                            cfg_heat_limit, heat_flat[31:16], cfg_max_hp, hp_flat[31:16]};
    wire [15:0] l_hp     = lr ? hp_flat[31:16]     : hp_flat[15:0];
    wire [15:0] l_heat   = lr ? heat_flat[31:16]   : heat_flat[15:0];
    wire [15:0] l_buffer = lr ? buffer_flat[31:16] : buffer_flat[15:0];

    // latched event data
    reg [7:0]  hurt_l, warn_lvl_l, warn_id_l, warn_cnt_l, shot_freq_l;
    reg [31:0] shot_speed_l;

    // event FIFO (8 deep): {hp, detail, kind, robot}
    reg [39:0] evq [0:7];
    reg [2:0]  ev_wp, ev_rp;
    reg [3:0]  ev_n;
    wire       ev_any = ev_n != 4'd0;

    // ------------------------------------------------------------- payloads
    wire [8*11-1:0] pl_0001 = {32'd0, unix_time, remain, {1'b0, stage}, game_type};
    wire [8*1-1:0]  pl_0002 = {6'd0, winner};
    // ally_1, ally_2, ally_3, ally_4, reserved, ally_7, outpost, base
    wire [8*16-1:0] pl_0003 = {80'd0, l_hp, 32'd0};
    wire [8*3-1:0]  pl_0104 = {warn_cnt_l, warn_id_l, warn_lvl_l};
    wire [8*13-1:0] pl_0201 = {{5'd0, l_flags[2], l_flags[3], l_flags[4]},
                               cfg_power_limit, cfg_heat_limit, cfg_cooling,
                               cfg_max_hp, l_hp, 8'd1, (lr ? 8'd103 : 8'd3)};
    // reserved(2), reserved(2), reserved(4), buffer, 17 mm heat, 42 mm heat
    wire [8*14-1:0] pl_0202 = {16'd0, l_heat, l_buffer, 64'd0};
    wire [8*1-1:0]  pl_0206 = hurt_l;
    wire [8*7-1:0]  pl_0207 = {shot_speed_l, shot_freq_l, 8'd1, 8'd1};
    wire [8*66-1:0] pl_F101 = {cfg_speed_limit, cfg_setup_time, cfg_hit_dmg, cfg_cooling,
                               cfg_combat_time, rx_err, rx_ok,
                               blk1, blk0,
                               {4'd0, game_type}, {7'd0, lr}, win_reason, {6'd0, winner},
                               remain, {3'd0, first_shot, first_dmg, paused}, {5'd0, stage}};
    wire [8*5-1:0]  pl_F102 = evq[ev_rp];

    // ----------------------------------------------------------- scheduling
    reg [NP-1:0] pend;
    reg [5:0]    c50;   // 20 ms ticks within 1 s
    reg [2:0]    c5;
    reg [4:0]    c17;

    reg [NP-1:0] pick;      // one-hot winner of the priority scan
    integer k;
    always @(*) begin
        pick = {NP{1'b0}};
        for (k = NP - 1; k >= 0; k = k - 1)
            if (pend[k] || (k == P_EV && ev_any)) begin
                pick    = {NP{1'b0}};
                pick[k] = 1'b1;
            end
    end

    // ----------------------------------------------------------- serializer
    reg           busy;
    reg [7:0]     b;
    reg [7:0]     plen;
    reg [15:0]    cmd;
    reg [PLW-1:0] pl;
    reg [7:0]     crc8;
    reg [15:0]    crc16;
    reg [7:0]     seq;

    wire [7:0] cur_byte =
        (b == 8'd0)        ? 8'hA5 :
        (b == 8'd1)        ? plen :
        (b == 8'd2)        ? 8'h00 :
        (b == 8'd3)        ? seq :
        (b == 8'd4)        ? crc8 :
        (b == 8'd5)        ? cmd[7:0] :
        (b == 8'd6)        ? cmd[15:8] :
        (b < 8'd7 + plen)  ? pl[7:0] :
        (b == 8'd7 + plen) ? crc16[7:0] : crc16[15:8];

    reg [NP-1:0] clr, set;
    reg [3:0]    n_in;
    reg [2:0]    wp;

    always @(posedge clk) begin
        fifo_wr <= 1'b0;
        clr = {NP{1'b0}};
        if (rst) begin
            pend <= {NP{1'b0}};
            c50 <= 6'd0; c5 <= 3'd0; c17 <= 5'd0;
            busy <= 1'b0; seq <= 8'd0;
            ev_wp <= 3'd0; ev_rp <= 3'd0; ev_n <= 4'd0;
            hurt_l <= 8'd0; shot_freq_l <= 8'd0; shot_speed_l <= 32'd0;
            warn_lvl_l <= 8'd0; warn_id_l <= 8'd0; warn_cnt_l <= 8'd0;
        end else begin
            if (busy) begin
                fifo_wr  <= 1'b1;
                fifo_din <= cur_byte;
                if (b < 8'd4)        crc8  <= crc8_byte(crc8, cur_byte);
                if (b < 8'd7 + plen) crc16 <= crc16_byte(crc16, cur_byte);
                if (b >= 8'd7 && b < 8'd7 + plen) pl <= pl >> 8;
                if (b == 8'd8 + plen) begin
                    busy <= 1'b0;
                    seq  <= seq + 8'd1;
                end
                b <= b + 8'd1;
            end else if (pick != {NP{1'b0}} && fifo_free >= 11'd80) begin
                busy  <= 1'b1;
                b     <= 8'd0;
                crc8  <= 8'hFF;
                crc16 <= 16'hFFFF;
                clr   = pick;
                case (1'b1)
                    pick[P_HURT]:   begin cmd <= 16'h0206; plen <= 8'd1;  pl <= pl_0206; end
                    pick[P_SHOT]:   begin cmd <= 16'h0207; plen <= 8'd7;  pl <= pl_0207; end
                    pick[P_WARN]:   begin cmd <= 16'h0104; plen <= 8'd3;  pl <= pl_0104; end
                    pick[P_RESULT]: begin cmd <= 16'h0002; plen <= 8'd1;  pl <= pl_0002; end
                    pick[P_STAT]:   begin cmd <= 16'h0001; plen <= 8'd11; pl <= pl_0001; end
                    pick[P_EV]:     begin cmd <= 16'hF102; plen <= 8'd5;  pl <= pl_F102; end
                    pick[P_RS]:     begin cmd <= 16'h0201; plen <= 8'd13; pl <= pl_0201; end
                    pick[P_PH]:     begin cmd <= 16'h0202; plen <= 8'd14; pl <= pl_0202; end
                    pick[P_HP]:     begin cmd <= 16'h0003; plen <= 8'd16; pl <= pl_0003; end
                    default:        begin cmd <= 16'hF101; plen <= 8'd66; pl <= pl_F101; end
                endcase
            end

            // Event queue: pop one on frame start, push up to two (A then B).
            // Events that do not fit are dropped (the queue only overflows if
            // the browser link stalls).
            if (clr[P_EV]) ev_rp <= ev_rp + 3'd1;
            n_in = 4'd0;
            wp = ev_wp;
            if (ev_valid[0] && ev_n + n_in < 4'd8 + (clr[P_EV] ? 4'd1 : 4'd0)) begin
                evq[wp] <= {ev_hp[15:0], ev_detail[7:0], ev_kind[7:0], 7'd0, ev_robot[0]};
                wp = wp + 3'd1;
                n_in = n_in + 4'd1;
            end
            if (ev_valid[1] && ev_n + n_in < 4'd8 + (clr[P_EV] ? 4'd1 : 4'd0)) begin
                evq[wp] <= {ev_hp[31:16], ev_detail[15:8], ev_kind[15:8], 7'd0, ev_robot[1]};
                wp = wp + 3'd1;
                n_in = n_in + 4'd1;
            end
            ev_wp <= wp;
            ev_n  <= ev_n + n_in - (clr[P_EV] ? 4'd1 : 4'd0);

            // periodic requests
            if (tick_20ms) begin
                c50 <= (c50 == 6'd49) ? 6'd0 : c50 + 6'd1;
                c5  <= (c5 == 3'd4)   ? 3'd0 : c5 + 3'd1;
                c17 <= (c17 == 5'd16) ? 5'd0 : c17 + 5'd1;
            end

            // set wins over clear so nothing requested this cycle is lost
            set = {NP{1'b0}};
            set[P_HURT]   = hurt_valid;
            set[P_SHOT]   = shot_valid;
            set[P_WARN]   = warn_valid || (tick_20ms && c50 == 6'd25);
            set[P_RESULT] = result_valid;
            set[P_STAT]   = stage_valid || (tick_20ms && c50 == 6'd0);
            set[P_RS]     = tick_20ms && c5 == 3'd0;
            set[P_PH]     = tick_20ms && c5 == 3'd1;
            set[P_HP]     = tick_20ms && c17 == 5'd0;
            set[P_SRV]    = tick_20ms && c5 == 3'd3;
            pend <= (pend & ~clr) | set;

            if (hurt_valid) hurt_l <= hurt_byte;
            if (shot_valid) begin shot_freq_l <= shot_freq; shot_speed_l <= shot_speed; end
            if (warn_valid) begin
                warn_lvl_l <= warn_level; warn_id_l <= warn_id; warn_cnt_l <= warn_count;
            end
        end
    end
endmodule
