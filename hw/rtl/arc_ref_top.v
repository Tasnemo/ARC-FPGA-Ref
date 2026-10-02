`timescale 1ns / 1ps
// Referee system without the bus interface: bytes in from the browser,
// frames out to the TX FIFO, board buttons/switches/LEDs.
//
//   BTN0..3 : armor hit on plate 0..3 (front, left, back, right)
//   SW0     : robot the buttons hit (0 red, 1 blue)
//   LED0    : combat running (blinks while paused)
//   LED1/2  : red / blue robot alive
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
    wire [127:0] cmd_data;

    arc_rx_parser #(.MAXLEN(16)) u_rx (
        .clk(clk), .rst(rst), .in_valid(rx_valid), .in_byte(rx_byte),
        .cmd_valid(cmd_valid), .cmd_id(cmd_id), .cmd_len(cmd_len), .cmd_data(cmd_data),
        .ok_count(rx_ok), .err_count(rx_err)
    );

    wire        tick_20ms;
    wire [2:0]  stage;
    wire        paused;
    wire [15:0] remain;
    wire [1:0]  winner;
    wire [3:0]  game_type;
    wire        link_robot;
    wire [31:0] unix_time;
    wire [15:0] cfg_combat_time, cfg_max_hp, cfg_heat_limit, cfg_cooling,
                cfg_power_limit, cfg_hit_dmg;
    wire [31:0] hp_flat, heat_flat, buffer_flat, power_flat;
    wire [15:0] yellow_flat;
    wire [1:0]  alive_flat, red_card_flat;
    wire        ev_valid, ev_robot;
    wire [7:0]  ev_kind, ev_detail;
    wire [15:0] ev_hp;
    wire        hurt_valid, shot_valid, warn_valid, result_valid, stage_valid;
    wire [7:0]  hurt_byte, shot_freq, warn_level, warn_id, warn_count;
    wire [31:0] shot_speed;

    arc_ref_core #(.CLK_HZ(CLK_HZ)) u_core (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_id(cmd_id), .cmd_len(cmd_len), .cmd_data(cmd_data),
        .btn_hit(btn_press), .btn_target(sw_level[0]),
        .tick_20ms(tick_20ms),
        .stage(stage), .paused(paused), .remain(remain), .winner(winner),
        .game_type(game_type), .link_robot(link_robot), .unix_time(unix_time),
        .cfg_combat_time(cfg_combat_time), .cfg_max_hp(cfg_max_hp),
        .cfg_heat_limit(cfg_heat_limit), .cfg_cooling(cfg_cooling),
        .cfg_power_limit(cfg_power_limit), .cfg_hit_dmg(cfg_hit_dmg),
        .hp_flat(hp_flat), .heat_flat(heat_flat), .buffer_flat(buffer_flat),
        .power_flat(power_flat), .yellow_flat(yellow_flat),
        .alive_flat(alive_flat), .red_card_flat(red_card_flat),
        .ev_valid(ev_valid), .ev_robot(ev_robot), .ev_kind(ev_kind),
        .ev_detail(ev_detail), .ev_hp(ev_hp),
        .hurt_valid(hurt_valid), .hurt_byte(hurt_byte),
        .shot_valid(shot_valid), .shot_freq(shot_freq), .shot_speed(shot_speed),
        .warn_valid(warn_valid), .warn_level(warn_level), .warn_id(warn_id),
        .warn_count(warn_count),
        .result_valid(result_valid), .stage_valid(stage_valid)
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
        .stage(stage), .paused(paused), .remain(remain), .winner(winner),
        .game_type(game_type), .link_robot(link_robot), .unix_time(unix_time),
        .cfg_combat_time(cfg_combat_time), .cfg_max_hp(cfg_max_hp),
        .cfg_heat_limit(cfg_heat_limit), .cfg_cooling(cfg_cooling),
        .cfg_power_limit(cfg_power_limit), .cfg_hit_dmg(cfg_hit_dmg),
        .hp_flat(hp_flat), .heat_flat(heat_flat), .buffer_flat(buffer_flat),
        .power_flat(power_flat), .yellow_flat(yellow_flat),
        .alive_flat(alive_flat), .red_card_flat(red_card_flat),
        .rx_ok(rx_ok), .rx_err(rx_err),
        .ev_valid(ev_valid), .ev_robot(ev_robot), .ev_kind(ev_kind),
        .ev_detail(ev_detail), .ev_hp(ev_hp),
        .hurt_valid(hurt_valid), .hurt_byte(hurt_byte),
        .shot_valid(shot_valid), .shot_freq(shot_freq), .shot_speed(shot_speed),
        .warn_valid(warn_valid), .warn_level(warn_level), .warn_id(warn_id),
        .warn_count(warn_count),
        .result_valid(result_valid), .stage_valid(stage_valid),
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
    assign led[1] = alive_flat[0];
    assign led[2] = alive_flat[1];
    assign led[3] = flash_cnt != 0;
endmodule
