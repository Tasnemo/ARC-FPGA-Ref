## Kria KR260 Robotics Starter Kit (K26 SOM, xck26-sfvc784-2LV-c).
## Pins taken from AMD's kria-vitis-platforms KR260 designs
## (kr260_pmod_gps / kr260_tsn_rs485pmod pin_timing.xdc).
##
## The clock (pl_clk0) and reset come from the PS, and the browser link runs
## over the network through Linux, so only the wired robot UART and the fan
## pin are constrained here.

## Wired robot link on PMOD 1, bottom row (the same pins AMD's PmodGPS and
## PmodRS485 examples use for their UART):
##   pin 8  = TX to the robot     (E12)
##   pin 9  = RX from the robot   (D11)
##   pin 11 = GND
## 3.3 V, 115200 8N1. Used for a wired robot, or for a radio module such as
## an ESP32 running ESP-NOW. The WiFi path does not need these pins.
set_property -dict { PACKAGE_PIN E12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports { robot_tx }]
set_property -dict { PACKAGE_PIN D11 IOSTANDARD LVCMOS33 PULLUP true }       [get_ports { robot_rx }]

## SOM fan enable (active low). Held low so the fan always runs; AMD's
## designs drive it from a PWM, which this design doesn't need.
set_property -dict { PACKAGE_PIN A12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports { fan_en_b }]

## The UART pins are slow and go through synchronisers.
set_false_path -from [get_ports robot_rx]
set_false_path -to   [get_ports {robot_tx fan_en_b}]
