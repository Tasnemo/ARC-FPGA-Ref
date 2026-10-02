`timescale 1ns / 1ps
// Referee system without the bus interface: bytes in from the browser,
// frames out to the TX FIFO, board buttons/switches/LEDs.
//
//   BTN0..3 : armor hit on plate 0..3 (front, left, back, right)
//   SW0     : team the buttons hit (0 red, 1 blue)
//   SW2:1   : robot the buttons hit: 00 Infantry, 01 Hero, 10 Sentry
//   LED0    : combat running (blinks while paused)
//   LED1/2  : a red / blue robot is alive
//   LED3    : flashes on each accepted control frame
module arc_ref_top #(
    parameter integer CLK_HZ      = 100_000_000,
    parameter integer DEBOUNCE_MS = 10,
    parameter integer FIFO_AW     = 10
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        rx_valid,
    input  wire [7:0]  rx_byte,

    input  wire        tx_rd,
    output wire [7:0]  tx_byte,
    output wire        tx_empty,
    output wire [FIFO_AW:0] tx_count,

    output wire [15:0] rx_ok,
    output wire [15:0] rx_err,

    input  wire [3:0]  btn,
    input  wire [3:0]  sw,
    output wire [3:0]  led,
    output wire [7:0]  inputs_level
);
    wire [3:0] btn_press, btn_level, sw_level;
    assign inputs_level = {sw_level, btn_level};

    arc_inputs #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) u_in (
        .clk(clk), .rst(rst), .btn_raw(btn), .sw_raw(sw),
        .btn_press(btn_press), .btn_level(btn_level), .sw_level(sw_level)
    );

    wire         cmd_valid;
    wire [15:0]  cmd_id;
    wire [7:0]   cmd_len;
    wire [191:0] cmd_data;

    arc_rx_parser #(.MAXLEN(24)) u_rx (
        .clk(clk), .rst(rst), .in_valid(rx_valid), .in_byte(rx_byte),
        .cmd_valid(cmd_valid), .cmd_id(cmd_id), .cmd_len(cmd_len), .cmd_data(cmd_data),
        .ok_count(rx_ok), .err_count(rx_err)
    );

    wire tick_20ms;
    wire [2:0] stage;
    wire paused;
    wire [15:0] remain;
    wire [1:0] winner;
    wire [7:0] win_reason;
    wire [1:0] first_dmg;
    wire [1:0] first_shot;
    wire [1:0] cap_holder;
    wire [3:0] game_type;
    wire [2:0] link_robot;
    wire [31:0] unix_time;
    wire [15:0] cfg_combat_time;
    wire [15:0] cfg_setup_time;
    wire [95:0] hp_flat;
    wire [95:0] maxhp_flat;
    wire [95:0] heat10_flat;
    wire [95:0] heatlim_flat;
    wire [95:0] buf10_flat;
    wire [95:0] power_flat;
    wire [95:0] plim_flat;
    wire [95:0] ammo_flat;
    wire [95:0] shots_flat;
    wire [95:0] cool_flat;
    wire [95:0] spdlim_flat;
    wire [47:0] yellow_flat;
    wire [47:0] rflags_flat;
    wire [47:0] rflags2_flat;
    wire [47:0] choff_flat;
    wire [95:0] spdlk_flat;
    wire [95:0] timer_flat;
    wire [31:0] vp_flat;
    wire [31:0] coins_flat;
    wire [31:0] dmg_flat;
    wire [1:0] hero_live_flat;
    wire [1:0] in_resupply_flat;
    wire [1:0] ev_valid;
    wire [5:0] ev_robot;
    wire [15:0] ev_kind;
    wire [15:0] ev_detail;
    wire [31:0] ev_hp;
    wire hurt_valid;
    wire [7:0] hurt_byte;
    wire shot_valid;
    wire [7:0] shot_freq;
    wire [31:0] shot_speed;
    wire warn_valid;
    wire [7:0] warn_level;
    wire [7:0] warn_id;
    wire [7:0] warn_count;
    wire result_valid;
    wire stage_valid;

    // SW0: team (0 red, 1 blue). SW2:1: 00 Infantry, 01 Hero, 10 Sentry.
    wire [2:0] btn_slot = (sw_level[0] ? 3'd3 : 3'd0) +
                          ((sw_level[2:1] == 2'b01) ? 3'd0 : (sw_level[2:1] == 2'b10) ? 3'd2 : 3'd1);

    arc_ref_core #(.CLK_HZ(CLK_HZ)) u_core (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_id(cmd_id), .cmd_len(cmd_len), .cmd_data(cmd_data),
        .btn_hit(btn_press), .btn_target(btn_slot),
        .tick_20ms(tick_20ms),
        .stage(stage),
        .paused(paused),
        .remain(remain),
        .winner(winner),
        .win_reason(win_reason),
        .first_dmg(first_dmg),
        .first_shot(first_shot),
        .cap_holder(cap_holder),
        .game_type(game_type),
        .link_robot(link_robot),
        .unix_time(unix_time),
        .cfg_combat_time(cfg_combat_time),
        .cfg_setup_time(cfg_setup_time),
        .hp_flat(hp_flat),
        .maxhp_flat(maxhp_flat),
        .heat10_flat(heat10_flat),
        .heatlim_flat(heatlim_flat),
        .buf10_flat(buf10_flat),
        .power_flat(power_flat),
        .plim_flat(plim_flat),
        .ammo_flat(ammo_flat),
        .shots_flat(shots_flat),
        .cool_flat(cool_flat),
        .spdlim_flat(spdlim_flat),
        .yellow_flat(yellow_flat),
        .rflags_flat(rflags_flat),
        .rflags2_flat(rflags2_flat),
        .choff_flat(choff_flat),
        .spdlk_flat(spdlk_flat),
        .timer_flat(timer_flat),
        .vp_flat(vp_flat),
        .coins_flat(coins_flat),
        .dmg_flat(dmg_flat),
        .hero_live_flat(hero_live_flat),
        .in_resupply_flat(in_resupply_flat),
        .ev_valid(ev_valid),
        .ev_robot(ev_robot),
        .ev_kind(ev_kind),
        .ev_detail(ev_detail),
        .ev_hp(ev_hp),
        .hurt_valid(hurt_valid),
        .hurt_byte(hurt_byte),
        .shot_valid(shot_valid),
        .shot_freq(shot_freq),
        .shot_speed(shot_speed),
        .warn_valid(warn_valid),
        .warn_level(warn_level),
        .warn_id(warn_id),
        .warn_count(warn_count),
        .result_valid(result_valid),
        .stage_valid(stage_valid)
    );

    wire       fifo_wr;
    wire [7:0] fifo_din;
    wire       fifo_full;
    wire [FIFO_AW:0] fifo_count;
    wire [FIFO_AW+1:0] free_wide = (1 << FIFO_AW) - fifo_count;
    wire [10:0] fifo_free = (free_wide > 2047) ? 11'd2047 : free_wide[10:0];
    assign tx_count = fifo_count;

    arc_frame_gen u_gen (
        .clk(clk), .rst(rst), .tick_20ms(tick_20ms),
        .stage(stage),
        .paused(paused),
        .remain(remain),
        .winner(winner),
        .win_reason(win_reason),
        .first_dmg(first_dmg),
        .first_shot(first_shot),
        .cap_holder(cap_holder),
        .game_type(game_type),
        .link_robot(link_robot),
        .unix_time(unix_time),
        .cfg_combat_time(cfg_combat_time),
        .cfg_setup_time(cfg_setup_time),
        .hp_flat(hp_flat),
        .maxhp_flat(maxhp_flat),
        .heat10_flat(heat10_flat),
        .heatlim_flat(heatlim_flat),
        .buf10_flat(buf10_flat),
        .power_flat(power_flat),
        .plim_flat(plim_flat),
        .ammo_flat(ammo_flat),
        .shots_flat(shots_flat),
        .cool_flat(cool_flat),
        .spdlim_flat(spdlim_flat),
        .yellow_flat(yellow_flat),
        .rflags_flat(rflags_flat),
        .rflags2_flat(rflags2_flat),
        .choff_flat(choff_flat),
        .spdlk_flat(spdlk_flat),
        .timer_flat(timer_flat),
        .vp_flat(vp_flat),
        .coins_flat(coins_flat),
        .dmg_flat(dmg_flat),
        .hero_live_flat(hero_live_flat),
        .in_resupply_flat(in_resupply_flat),
        .ev_valid(ev_valid),
        .ev_robot(ev_robot),
        .ev_kind(ev_kind),
        .ev_detail(ev_detail),
        .ev_hp(ev_hp),
        .hurt_valid(hurt_valid),
        .hurt_byte(hurt_byte),
        .shot_valid(shot_valid),
        .shot_freq(shot_freq),
        .shot_speed(shot_speed),
        .warn_valid(warn_valid),
        .warn_level(warn_level),
        .warn_id(warn_id),
        .warn_count(warn_count),
        .result_valid(result_valid),
        .stage_valid(stage_valid),
        .rx_ok(rx_ok), .rx_err(rx_err),
        .fifo_wr(fifo_wr), .fifo_din(fifo_din), .fifo_free(fifo_free)
    );

    arc_byte_fifo #(.AW(FIFO_AW)) u_fifo (
        .clk(clk), .rst(rst),
        .wr(fifo_wr), .din(fifo_din),
        .rd(tx_rd), .dout(tx_byte), .empty(tx_empty), .full(fifo_full),
        .count(fifo_count)
    );

    // ----------------------------------------------------------------- LEDs
    localparam integer BLINK_DIV = CLK_HZ / 4;     // 2 Hz blink
    localparam integer FLASH_LEN = CLK_HZ / 20;    // 50 ms flash
    reg [31:0] blink_cnt, flash_cnt;
    reg        blink;
    always @(posedge clk) begin
        if (rst) begin
            blink_cnt <= 0; blink <= 1'b0; flash_cnt <= 0;
        end else begin
            if (blink_cnt == BLINK_DIV - 1) begin
                blink_cnt <= 0; blink <= ~blink;
            end else begin
                blink_cnt <= blink_cnt + 1;
            end
            if (cmd_valid)          flash_cnt <= FLASH_LEN;
            else if (flash_cnt != 0) flash_cnt <= flash_cnt - 1;
        end
    end

    assign led[0] = (stage == 3'd4) && (!paused || blink);
    assign led[1] = rflags_flat[0] | rflags_flat[8]  | rflags_flat[16];   // any red robot alive
    assign led[2] = rflags_flat[24] | rflags_flat[32] | rflags_flat[40];  // any blue robot alive
    assign led[3] = flash_cnt != 0;
endmodule
